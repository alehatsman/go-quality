#!/usr/bin/env bash
# ci/fast.sh — shared pre-commit gate. Cheap checks only (<5s on warm cache).
#
#   [1/4] go vet
#   [2/4] gofmt on staged Go files
#   [3/4] ai-lint on staged Go files
#   [4/4] code-quality soft-cap budget
#
# First failure stops the pipeline. This is the project-agnostic core; projects
# that need extra fast checks (docs/schema regen, etc.) layer them in their own
# task after invoking this gate.
#
# Honors $GO_TAGS (e.g. sqlite_fts5) for the vet pass. $PKG defaults to ./...
set -euo pipefail

PKG="${PKG:-./...}"
GO_TAGS="${GO_TAGS:-}"
tags_args=()
[ -n "$GO_TAGS" ] && tags_args=(-tags "$GO_TAGS")

# Resolve the scripts/ dir (parent of this ci/ dir) so the sibling scripts
# resolve regardless of cwd.
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$(git rev-parse --show-toplevel)"

# ── [1/4] go vet ───────────────────────────────────────────────────────
echo "[1/4] go vet"
go vet "${tags_args[@]+"${tags_args[@]}"}" "$PKG"

# ── [2/4] gofmt on staged Go files ────────────────────────────────────
echo "[2/4] gofmt (staged Go files)"
staged=$(git diff --cached --name-only --diff-filter=ACMR -- '*.go' || true)
if [ -z "$staged" ]; then
  echo "  (no staged Go files)"
else
  bad=$(echo "$staged" | xargs gofmt -l 2>/dev/null || true)
  if [ -n "$bad" ]; then
    echo "  ✗ gofmt would change:" >&2
    echo "$bad" | sed 's/^/    /' >&2
    echo "  fix with: gofmt -w <files>" >&2
    exit 1
  fi
  echo "  ✓ all staged files formatted"
fi

# ── [3/4] ai-lint on staged Go files ──────────────────────────────────
echo "[3/4] ai-lint (staged Go files)"
bash "$SCRIPTS_DIR/ai-lint.sh"

# ── [4/4] soft-cap budget ─────────────────────────────────────────────
echo "[4/4] code-quality soft-cap budget"
bash "$SCRIPTS_DIR/budget-status.sh" | sed 's/^/  /'

echo
echo "✓ Fast checks green — full gate (scripts/ci/full.sh) runs on push."
