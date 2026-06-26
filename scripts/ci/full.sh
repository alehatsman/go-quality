#!/usr/bin/env bash
# ci/full.sh — shared pre-push gate. First failure stops the pipeline.
#
#   [1/7] build (compile-check ./...)
#   [2/7] test
#   [3/7] golangci-lint (worktree-scoped cache; sibling-safe)
#   [4/7] govulncheck
#   [5/7] arch-snapshot summary (regenerated; file is gitignored)
#   [6/7] code-quality soft-cap budget
#   [7/7] dupl production duplication report (informational)
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

echo "[1/7] build"
go build "${tags_args[@]+"${tags_args[@]}"}" "$PKG"

echo "[2/7] test"
go test "${tags_args[@]+"${tags_args[@]}"}" "$PKG"

echo "[3/7] golangci-lint (worktree-scoped cache)"
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

echo "[4/7] govulncheck"
govulncheck "${tags_args[@]+"${tags_args[@]}"}" "$PKG"

echo "[5/7] arch-snapshot (regenerated; file is gitignored)"
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

echo "[6/7] code-quality soft-cap budget"
bash "$SCRIPTS_DIR/budget-status.sh" | sed 's/^/  /'

echo "[7/7] dupl (production-code duplication report)"
bash "$SCRIPTS_DIR/dupl-report.sh" --ci

echo
echo "✓ All checks green — safe to push."
