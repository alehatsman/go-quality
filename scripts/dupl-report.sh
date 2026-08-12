#!/usr/bin/env bash
# Code-duplication report (production code only).
#
# Usage:
#   scripts/dupl-report.sh           # manual mode, threshold 100
#   scripts/dupl-report.sh --ci      # CI mode (graceful skip if dupl missing, 2-space indent)
#
# Override threshold with T env var: T=50 scripts/dupl-report.sh
#
# Pipes `dupl -plumbing` through a Python deduper that pairs each clone with its
# mate and reports them sorted by clone length. dupl emits one line per
# direction (A → B and B → A as separate entries); the deduper collapses those.
set -euo pipefail

CI_MODE=0
FORMAT="text"
while [ $# -gt 0 ]; do
  case "$1" in
    --ci)       CI_MODE=1; shift ;;
    --format)   FORMAT="${2:-}"; shift 2 ;;
    --format=*) FORMAT="${1#*=}"; shift ;;
    *) shift ;;
  esac
done

T="${T:-100}"

if ! command -v dupl >/dev/null 2>&1 && ! [ -x "$(go env GOPATH)/bin/dupl" ]; then
  # jsonl is a findings feed — a missing tool yields no findings, never a message.
  [ "$FORMAT" = "jsonl" ] && exit 0
  if [ "$CI_MODE" = "1" ]; then
    echo "  dupl not installed — run scripts/install-tools.sh. Skipping."
    exit 0
  fi
  echo "dupl not installed — run scripts/install-tools.sh." >&2
  exit 1
fi

INDENT=""
[ "$CI_MODE" = "1" ] && INDENT="  "

# Clone pairs are informational (dupl never fails the gate) → level:warning.
dupl -threshold "$T" -plumbing . 2>&1 | grep -v "_test.go" | T="$T" INDENT="$INDENT" FORMAT="$FORMAT" python3 -c '
import os, sys, json
T = os.environ.get("T", "100")
INDENT = os.environ.get("INDENT", "")
FORMAT = os.environ.get("FORMAT", "text")
pairs = set()
for line in sys.stdin:
    parts = line.strip().split(": duplicate of ")
    if len(parts) != 2: continue
    pairs.add(tuple(sorted(parts)))
def n(rng):
    lo, hi = rng.split(":")[-1].split("-"); return int(hi) - int(lo) + 1
def loc(item):                      # "path/file.go:lo-hi" -> (path, lo)
    path, _, rng = item.rpartition(":")
    return path, int(rng.split("-")[0])
# Stable order: size desc, then lexicographic — a set has no deterministic
# iteration order, so tie-break explicitly (deterministic findings dedup + diff).
ranked = sorted(pairs, key=lambda p: (-n(p[0]), p[0], p[1]))
if FORMAT == "jsonl":
    for a, b in ranked:
        pa, la = loc(a)
        print(json.dumps({"tool": "dupl", "rule": "clone-pair", "level": "warning",
                          "path": pa, "line": la,
                          "message": f"{n(a)}L clone: {a} <--> {b}",
                          "fingerprint": f"clone-pair:{pa}:{la}"}))
elif not ranked:
    print(f"{INDENT}no production duplication at threshold {T}.")
else:
    print(f"{INDENT}{len(ranked)} production clone pair(s) at threshold {T}:")
    for a, b in ranked:
        print(f"{INDENT}  {n(a):>3}L  {a}  <-->  {b}")
'
