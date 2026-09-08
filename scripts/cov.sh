#!/usr/bin/env bash
# cov — test coverage report with an opt-in monotonic floor.
#
# Coverage is a bad target and a decent smoke alarm. This script treats it that
# way: it always reports, and it only *fails* once a project commits a baseline,
# after which the number may rise freely and may not fall.
#
#   scripts/cov.sh                     # report only, exit 0
#   scripts/cov.sh --refresh           # write benchmark/coverage/baseline.txt
#   git add benchmark/coverage/baseline.txt   # commit to enable the floor
#
# Measurement is per-package (`go test -coverprofile`), NOT `-coverpkg=./...`.
# Cross-package coverage counts a handler exercised by an end-to-end test as
# coverage of the code it happens to reach, which flatters the number and hides
# untested units. Per-package is the honest default.
#
# Packages with no test files are reported separately and excluded from the
# total, so adding an untested package cannot silently dilute the floor — it
# shows up as its own finding instead.
#
# Rules:
#   cov_below_floor    [error]    total coverage fell below the committed floor
#   cov_untested_pkg   [warning]  package has no test files at all
#   cov_improved       [note]     total is above the floor — refresh to lock it in
#
# Output (one finding per line):
#   text  (default): path:line: rule: message
#   jsonl (--format jsonl): shared gate finding schema, one object per line.
#     stdout stays pure JSONL; human status/summary go to stderr.
#
# Env: PKG (./...), GO_TAGS, COV_MIN (0), COV_BASELINE
#      (benchmark/coverage/baseline.txt), GATE_DIR (.gate)
#
# Usage:
#   bash scripts/cov.sh [--refresh] [--format jsonl] [--warn-only] [--ci]
set -euo pipefail

PKG="${PKG:-./...}"
GO_TAGS="${GO_TAGS:-}"
COV_MIN="${COV_MIN:-0}"
COV_BASELINE="${COV_BASELINE:-benchmark/coverage/baseline.txt}"
GATE_DIR="${GATE_DIR:-.gate}"

tags_args=()
[ -n "$GO_TAGS" ] && tags_args=(-tags "$GO_TAGS")

format="text"
warn_only=0
ci_mode=0
refresh=0

while [ $# -gt 0 ]; do
  case "$1" in
    --format) format="${2:-}"; shift 2 ;;
    --format=*) format="${1#*=}"; shift ;;
    --refresh) refresh=1; shift ;;
    --warn-only) warn_only=1; shift ;;
    --ci) ci_mode=1; shift ;;
    -h|--help) sed -n '2,35p' "$0"; exit 0 ;;
    *) echo "cov: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib/findings.sh
. "$SCRIPTS_DIR/lib/findings.sh"
findings_init cov "$format" cov

cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

if [ ! -f go.mod ]; then
  if [ "$ci_mode" -eq 1 ]; then echo "cov: no go.mod at the repo root" >&2; exit 1; fi
  say "  cov: no go.mod — skipping."
  exit 0
fi

mkdir -p "$GATE_DIR"
profile="$GATE_DIR/coverage.out"
testlog="$GATE_DIR/coverage.log"

# --- run the suite with coverage ---------------------------------------------
# A failing test is a test failure, not a coverage finding — surface it as
# itself and stop. The log is kept so a caller can read the failure.
if ! go test "${tags_args[@]+"${tags_args[@]}"}" -coverprofile="$profile" "$PKG" > "$testlog" 2>&1; then
  say "  ✗ cov: tests failed — coverage not measured. See $testlog"
  sed -n '1,40p' "$testlog" >&2
  exit 1
fi

total="$(go tool cover -func="$profile" 2>/dev/null | awk '$1 == "total:" { sub(/%$/, "", $NF); print $NF; exit }')"
total="${total:-0}"

# --- refresh mode -------------------------------------------------------------
if [ "$refresh" -eq 1 ]; then
  mkdir -p "$(dirname "$COV_BASELINE")"
  {
    echo "# go-quality coverage floor, percent of statements."
    echo "# Regenerate with: scripts/cov.sh --refresh"
    echo "# Coverage may rise freely; a drop below this number fails goq/cov."
    echo "$total"
  } > "$COV_BASELINE"
  echo "  ✓ coverage baseline written: $COV_BASELINE (${total}%)"
  exit 0
fi

# --- packages with no test files ---------------------------------------------
# NOT parsed out of the test log. Plain `go test` marks these with
# "?   <pkg>  [no test files]", but under -coverprofile it prints the same line
# with the status and coverage columns *empty* — no "?" to match on. `go list`
# answers the question directly and does not depend on output formatting.
#
# These packages contribute no entries to the profile, so they are already
# absent from `go tool cover`'s total. Reporting them individually is what stops
# a new untested package from quietly lowering the bar it is measured against.
root="$(pwd)"
untested=0
while IFS=$'\t' read -r imp dir; do
  [ -n "$imp" ] || continue
  rel="${dir#"$root"/}"
  [ "$rel" = "$dir" ] && rel="."
  untested=$((untested + 1))
  emit cov_untested_pkg warning "$rel" 1 "$imp" \
    "package has no test files — excluded from the coverage total"
done < <(go list "${tags_args[@]+"${tags_args[@]}"}" \
  -f '{{if and (eq (len .TestGoFiles) 0) (eq (len .XTestGoFiles) 0)}}{{.ImportPath}}	{{.Dir}}{{end}}' \
  "$PKG" 2>/dev/null | grep -v '^[[:space:]]*$' || true)

# --- floor --------------------------------------------------------------------
floor="$COV_MIN"
floor_source="COV_MIN"
if [ -f "$COV_BASELINE" ]; then
  committed="$(grep -v '^#' "$COV_BASELINE" | grep -v '^[[:space:]]*$' | head -1 | tr -d ' ')"
  if [ -n "$committed" ]; then
    floor="$committed"
    floor_source="$COV_BASELINE"
  fi
fi

# Decimal comparison — bash does integers only, so awk arbitrates.
below=$(awk -v t="$total" -v f="$floor" 'BEGIN { print (t + 0 < f + 0) ? 1 : 0 }')
above=$(awk -v t="$total" -v f="$floor" 'BEGIN { print (t + 0 > f + 0 + 0.5) ? 1 : 0 }')

if [ "$below" = "1" ]; then
  emit cov_below_floor error go.mod 1 total \
    "total coverage ${total}% is below the floor ${floor}% (from $floor_source)"
elif [ "$above" = "1" ] && [ "$floor_source" != "COV_MIN" ]; then
  emit cov_improved note go.mod 1 total \
    "total coverage ${total}% is above the ${floor}% floor — run --refresh to lock it in"
fi

# --- report -------------------------------------------------------------------
say ""
say "  coverage: ${total}% of statements (floor ${floor}%, from $floor_source)"
say "  untested packages: $untested"
say "  profile: $profile   (browse: go tool cover -html=$profile)"

if [ "$FINDINGS_ERRORS" -eq 0 ]; then
  say "  ✓ cov: at or above the floor."
  exit 0
fi

say "  cov: $FINDINGS_COUNT finding(s), $FINDINGS_ERRORS error(s)."
[ "$warn_only" -eq 1 ] && exit 0
exit 1
