#!/usr/bin/env bash
# ci/full.sh — shared pre-push gate. First failure stops the pipeline.
#
#   [1/9] build (compile-check ./...)
#   [2/9] test
#   [3/9] go mod tidy drift check
#   [4/9] golangci-lint (worktree-scoped cache; sibling-safe)
#   [5/9] govulncheck
#   [6/9] arch-snapshot summary (regenerated; file is gitignored)
#   [7/9] code-quality soft-cap budget
#   [8/9] dupl production duplication report (informational)
#   [9/9] structure-ratchet (opt-in; enforces structural metrics vs baseline)
#
# This is the project-agnostic core. Projects that need extra gates (docs/schema
# regen + verify-clean, mkdocs --strict, bespoke lints) layer them in their own
# task after invoking this gate.
#
# Honors $GO_TAGS (e.g. sqlite_fts5) across build/test/vet/lint/vuln so the
# whole gate compiles the same file set. $PKG defaults to ./...
#
# Run -race tests separately; they roughly double wall-clock time and the
# production lint catches most of what -race would flag at this scale.
set -euo pipefail

PKG="${PKG:-./...}"
GO_TAGS="${GO_TAGS:-}"
tags_args=()
[ -n "$GO_TAGS" ] && tags_args=(-tags "$GO_TAGS")

# Resolve the scripts/ dir (parent of this ci/ dir) so the sibling scripts
# resolve regardless of cwd.
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$(git rev-parse --show-toplevel)"

echo "[1/9] build"
go build "${tags_args[@]+"${tags_args[@]}"}" "$PKG"

echo "[2/9] test"
go test "${tags_args[@]+"${tags_args[@]}"}" "$PKG"

# Pre-commit (fast.sh) already guards this, but pre-push must not trust that a
# hook ran — a commit pushed from CI or with --no-verify can still drift go.mod.
echo "[3/9] go mod tidy (drift check)"
go mod tidy
if ! git diff --quiet go.mod go.sum; then
  echo "  ✗ go.mod / go.sum out of sync — run 'go mod tidy', commit the result, and re-push" >&2
  git checkout -- go.mod go.sum 2>/dev/null || true
  exit 1
fi
echo "  ✓ go.mod / go.sum are tidy"

echo "[4/9] golangci-lint (worktree-scoped cache)"
# Scope the cache to this checkout path so sibling worktrees don't leak phantom
# findings into each other. No clean needed — warm cache is reused across runs
# in the same worktree.
_lint_cache_key=$(printf '%s' "$(git rev-parse --show-toplevel)" | sha256sum | cut -c1-12)
export GOLANGCI_LINT_CACHE="${HOME}/.cache/golangci-lint/${_lint_cache_key}"
if [ -n "$GO_TAGS" ]; then
  golangci-lint run --build-tags "$GO_TAGS" "$PKG"
else
  golangci-lint run "$PKG"
fi

echo "[5/9] govulncheck"
govulncheck "${tags_args[@]+"${tags_args[@]}"}" "$PKG"

echo "[6/9] arch-snapshot (regenerated; file is gitignored)"
GO_TAGS="$GO_TAGS" bash "$SCRIPTS_DIR/arch-snapshot.sh" >/dev/null
snap=docs-working/ARCH_SNAPSHOT.md
if [ -f "$snap" ]; then
  # awk | head closes the pipe early and SIGPIPEs awk; under pipefail that
  # fails the script. Scope pipefail off for these best-effort summary pipes.
  set +o pipefail
  echo "  Top packages by LOC:"
  awk '/^\| `/{print "    " $0}' "$snap" | head -5
  god=$(awk '/^## God files/,/^## [^G]/' "$snap" | grep -cE '^[[:space:]]*[0-9]+ ' || true)
  echo "  God files (>500 LOC, non-test): $god"
  echo "  Top cyclomatic hotspots:"
  awk '/^## Cyclomatic hotspots/,/^## [^C]/' "$snap" | grep -E '^[[:space:]]*[0-9]+ ' | head -3 | sed 's/^/    /'
  set -o pipefail
fi

echo "[7/9] code-quality soft-cap budget"
bash "$SCRIPTS_DIR/budget-status.sh" | sed 's/^/  /'

echo "[8/9] dupl (production-code duplication report)"
bash "$SCRIPTS_DIR/dupl-report.sh" --ci

# Opt-in: skips cleanly for projects without benchmark/structure/baseline.json.
# --ci makes a missing tool fatal (consistent with the rest of the pre-push gate).
echo "[9/9] structure-ratchet (opt-in structural metric enforcement)"
# No pipe: piping through sed would swallow a non-zero exit under pipefail.
# The script indents its own output.
GO_TAGS="$GO_TAGS" DEADCODE_PKG="${DEADCODE_PKG:-./...}" \
  STRUCTURE_BASELINE="${STRUCTURE_BASELINE:-benchmark/structure/baseline.json}" \
  bash "$SCRIPTS_DIR/structure-ratchet.sh" --ci

echo
echo "✓ All checks green — safe to push."
