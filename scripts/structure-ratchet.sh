#!/usr/bin/env bash
# structure-ratchet — monotonic ratchet for structural code-quality metrics.
#
# The other shared checks (budget-status, dupl, deadcode) are informational-only:
# they PRINT drift but never fail, so god files, over-cap complexity, clone pairs
# and dead code can grow forever. This gate freezes each count in a committed
# baseline and fails when any count GROWS — a one-way door. Counts may shrink
# (baseline auto-tightens on --refresh), never grow.
#
# It is OPT-IN per project: with no baseline file present the check skips cleanly
# (exit 0), so it is safe to wire into the shared full gate for every consumer.
# A project opts in by running `--refresh` once and committing the baseline.
#
# Metrics (production code only, mirroring the other scripts):
#   god_files         files >CAP_GOD_LOC LOC        (budget-status.sh)
#   gocyclo_over      functions >CAP_GOCYCLO cyclo   (budget-status.sh)
#   dupl_pairs        clone pairs at threshold T     (dupl-report.sh)
#   deadcode_symbols  unreachable symbols from main  (deadcode $DEADCODE_PKG)
#
# Config (env):
#   STRUCTURE_BASELINE  baseline path       (default benchmark/structure/baseline.json)
#   CAP_GOD_LOC         god-file LOC cap     (default 500)
#   CAP_GOCYCLO         cyclomatic cap       (default 35)
#   DUPL_T              dupl token threshold (default 100)
#   DEADCODE_PKG        deadcode entry pkgs  (default ./...)
#   GO_TAGS             build tags           (default empty)
#
# Usage:
#   scripts/structure-ratchet.sh            # check; fail if any count grew
#   scripts/structure-ratchet.sh --refresh  # regenerate baseline from current tree
#   scripts/structure-ratchet.sh --ci       # missing tool is FATAL (default: warn+skip)
set -euo pipefail

CAP_GOCYCLO="${CAP_GOCYCLO:-35}"
CAP_GOD_LOC="${CAP_GOD_LOC:-500}"
DUPL_T="${DUPL_T:-100}"
DEADCODE_PKG="${DEADCODE_PKG:-./...}"
GO_TAGS="${GO_TAGS:-}"

REFRESH=0
CI_MODE=0
for a in "$@"; do
  case "$a" in
    --refresh) REFRESH=1 ;;
    --ci)      CI_MODE=1 ;;
    *) echo "structure-ratchet: unknown arg '$a'" >&2; exit 2 ;;
  esac
done

cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
BASELINE="${STRUCTURE_BASELINE:-benchmark/structure/baseline.json}"
GOBIN="$(go env GOPATH)/bin"

tags_args=()
[ -n "$GO_TAGS" ] && tags_args=(-tags "$GO_TAGS")

have() { command -v "$1" >/dev/null 2>&1 || [ -x "$GOBIN/$1" ]; }
run()  { if command -v "$1" >/dev/null 2>&1; then "$@"; else "$GOBIN/$1" "${@:2}"; fi; }

# missing_tool <name> — record a skipped metric; fatal in CI, warn otherwise.
missing_tool() {
  if [ "$CI_MODE" = "1" ]; then
    echo "structure-ratchet: $1 not installed (fatal in --ci) — run scripts/install-tools.sh" >&2
    exit 1
  fi
  echo "structure-ratchet: $1 not installed — skipping its metric (run scripts/install-tools.sh)" >&2
}

# ---- opt-in guard: no baseline and not refreshing → skip cleanly -------------
if [ "$REFRESH" != "1" ] && [ ! -f "$BASELINE" ]; then
  echo "  structure-ratchet: no baseline at $BASELINE — not opted in. Skipping."
  echo "  (run 'scripts/structure-ratchet.sh --refresh' once and commit it to enable.)"
  exit 0
fi

# ---- collect offender IDENTITY lists (one metric per temp file) --------------
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# god_files: identity = path (LOC-agnostic so a stable god file isn't spurious).
find . -name '*.go' -not -name '*_test.go' \
     -not -path './vendor/*' -not -path './.git/*' -not -path './.claude/*' \
     -exec wc -l {} + 2>/dev/null \
  | awk -v cap="$CAP_GOD_LOC" '$1 > cap && $2 != "total" {print $2}' \
  | sort > "$tmp/god_files"

# gocyclo_over: identity = "pkg.func @ pos".
if have gocyclo; then
  run gocyclo -over "$CAP_GOCYCLO" . 2>/dev/null | grep -v '_test\.go' \
    | awk '{print $2"."$3" "$4}' | sort > "$tmp/gocyclo_over" || true
else
  missing_tool gocyclo
fi

# dupl_pairs: identity = sorted clone pair (collapses A→B / B→A duplicates).
if have dupl; then
  run dupl -threshold "$DUPL_T" -plumbing . 2>&1 | grep -v '_test\.go' \
    | python3 -c '
import sys
pairs = set()
for line in sys.stdin:
    p = line.strip().split(": duplicate of ")
    if len(p) == 2:
        pairs.add(" <--> ".join(sorted(p)))
for x in sorted(pairs):
    print(x)
' > "$tmp/dupl_pairs" || true
else
  missing_tool dupl
fi

# deadcode_symbols: identity = full "file:line:col: unreachable ..." line.
if have deadcode; then
  run deadcode "${tags_args[@]+"${tags_args[@]}"}" "$DEADCODE_PKG" 2>/dev/null | sort > "$tmp/deadcode_symbols" || true
else
  missing_tool deadcode
fi

METRICS="god_files gocyclo_over dupl_pairs deadcode_symbols"

# ---- refresh: write baseline (only metrics we actually measured) -------------
if [ "$REFRESH" = "1" ]; then
  mkdir -p "$(dirname "$BASELINE")"
  python3 - "$BASELINE" "$tmp" $METRICS <<'PY'
import json, os, sys
out, tmp, metrics = sys.argv[1], sys.argv[2], sys.argv[3:]
data = {}
for m in metrics:
    f = os.path.join(tmp, m)
    if not os.path.exists(f):      # tool missing → leave metric out
        continue
    items = [l.rstrip("\n") for l in open(f) if l.strip()]
    data[m] = {"count": len(items), "items": items}
json.dump(data, open(out, "w"), indent=2, sort_keys=True)
open(out, "a").write("\n")
print(f"structure-ratchet: baseline written to {out}")
for m in metrics:
    if m in data:
        print(f"  {m:<18} {data[m]['count']}")
PY
  exit 0
fi

# ---- check: fail if any measured count grew over baseline --------------------
python3 - "$BASELINE" "$tmp" $METRICS <<'PY'
import json, os, sys
base_path, tmp, metrics = sys.argv[1], sys.argv[2], sys.argv[3:]
base = json.load(open(base_path))
failed = False
for m in metrics:
    f = os.path.join(tmp, m)
    if not os.path.exists(f):          # skipped (tool missing, non-CI) → ignore
        continue
    cur = [l.rstrip("\n") for l in open(f) if l.strip()]
    b = base.get(m)
    if b is None:
        print(f"  ~ {m:<18} not in baseline (count={len(cur)}) — run --refresh")
        continue
    bl_count, bl_items = b["count"], set(b.get("items", []))
    if len(cur) > bl_count:
        failed = True
        new = [x for x in cur if x not in bl_items]
        print(f"  ✗ {m:<18} {bl_count} -> {len(cur)}  (+{len(cur)-bl_count})")
        for x in new:
            print(f"        NEW  {x}")
    elif len(cur) < bl_count:
        print(f"  ↓ {m:<18} {bl_count} -> {len(cur)}  (improved — run --refresh to lock in)")
    else:
        print(f"  ✓ {m:<18} {bl_count}")
if failed:
    print("\nstructure-ratchet: structural metrics grew above baseline (ratchet). "
          "Reduce them, or if intentional re-run with --refresh and commit the baseline.")
    sys.exit(1)
print("\nstructure-ratchet: all structural metrics within baseline")
PY
