#!/usr/bin/env bash
# deps-status — dependency-surface hygiene for a Go module.
#
# Every direct dependency is code you ship, a module proxy you trust, and an
# `init()` you execute. Go has no dependency-policy tool; this is the nearest
# equivalent that does not drag in a new toolchain:
#
#   go mod verify        the module cache still matches go.sum          [error]
#   direct-dep count     soft cap, default 40                           [warning]
#   new direct deps      absent from a committed baseline (opt-in)      [error]
#   dropped deps         baseline entry that is gone — an improvement   [note]
#   available updates    --updates only; needs the network              [note]
#
# The new-dependency check is opt-in the same way the structural ratchet is:
# with no baseline file the script reports and exits 0, so it is safe in the
# shared gate for every consumer. Opt in once:
#
#   scripts/deps-status.sh --refresh          # writes benchmark/deps/baseline.txt
#   git add benchmark/deps/baseline.txt       # commit to enable enforcement
#
# After that, adding a direct dependency fails the gate until somebody
# re-refreshes the baseline in the same commit — which is exactly the review
# moment a new dependency deserves.
#
# Output (one finding per line):
#   text  (default): path:line: rule: message
#   jsonl (--format jsonl): shared gate finding schema, one object per line.
#     stdout stays pure JSONL; human status/summary go to stderr.
#
# Env: CAP_DIRECT_DEPS (40), DEPS_BASELINE (benchmark/deps/baseline.txt)
#
# Usage:
#   bash scripts/deps-status.sh                 # report (offline)
#   bash scripts/deps-status.sh --updates       # also report available updates
#   bash scripts/deps-status.sh --refresh       # rewrite the baseline
#   bash scripts/deps-status.sh --format jsonl  # structured findings
#   bash scripts/deps-status.sh --ci            # missing go/go.mod is fatal
set -euo pipefail

CAP_DIRECT_DEPS="${CAP_DIRECT_DEPS:-40}"
DEPS_BASELINE="${DEPS_BASELINE:-benchmark/deps/baseline.txt}"

format="text"
warn_only=0
ci_mode=0
refresh=0
updates=0

while [ $# -gt 0 ]; do
  case "$1" in
    --format) format="${2:-}"; shift 2 ;;
    --format=*) format="${1#*=}"; shift ;;
    --refresh) refresh=1; shift ;;
    --updates) updates=1; shift ;;
    --warn-only) warn_only=1; shift ;;
    --ci) ci_mode=1; shift ;;
    -h|--help) sed -n '2,37p' "$0"; exit 0 ;;
    *) echo "deps-status: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib/findings.sh
. "$SCRIPTS_DIR/lib/findings.sh"
findings_init deps "$format" deps-status

cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

if [ ! -f go.mod ]; then
  if [ "$ci_mode" -eq 1 ]; then
    echo "deps-status: no go.mod at the repo root" >&2
    exit 1
  fi
  say "  deps-status: no go.mod — skipping."
  exit 0
fi

# --- direct dependencies, parsed offline from go.mod --------------------------
# Handles both the block form and the single-line `require x v1` form, and skips
# `// indirect` entries. Go 1.27's `go mod tidy` merges requires into at most two
# blocks (direct, indirect); this parse is indifferent to how many there are.
direct_deps() {
  awk '
    /^require \(/            { inblk = 1; next }
    inblk && /^\)/           { inblk = 0; next }
    inblk && /\/\/ indirect/ { next }
    inblk && /^[[:space:]]*\/\// { next }
    inblk && NF >= 2         { print $1; next }
    /^require [^(]/ && !/\/\/ indirect/ { print $2 }
  ' go.mod | sort -u
}

deps="$(direct_deps)"
count=$(printf '%s\n' "$deps" | grep -c . || true)

# --- refresh mode -------------------------------------------------------------
if [ "$refresh" -eq 1 ]; then
  mkdir -p "$(dirname "$DEPS_BASELINE")"
  {
    echo "# go-quality direct-dependency baseline."
    echo "# Regenerate with: scripts/deps-status.sh --refresh"
    echo "# Adding a direct dependency fails goq/ci until this file is updated"
    echo "# in the same commit — that is the point."
    printf '%s\n' "$deps"
  } > "$DEPS_BASELINE"
  echo "  ✓ deps baseline written: $DEPS_BASELINE ($count direct dependencies)"
  exit 0
fi

# Line of a module path inside go.mod, so findings land where the human looks.
mod_line() {
  local n
  n=$(grep -n -F -m1 "$1 " go.mod 2>/dev/null | cut -d: -f1 || true)
  echo "${n:-1}"
}

# --- go mod verify ------------------------------------------------------------
# Confirms the module cache contents still hash to what go.sum recorded. Cheap
# and offline once the cache is warm; catches a tampered cache, not a malicious
# upstream (go.sum would have been updated for that — that is review's job).
if ! verify_out=$(go mod verify 2>&1); then
  emit mod_verify error go.sum 1 verify \
    "go mod verify failed: $(echo "$verify_out" | head -1)"
fi

# --- direct-dependency count --------------------------------------------------
if [ "$count" -gt "$CAP_DIRECT_DEPS" ]; then
  emit deps_over_cap warning go.mod 1 count \
    "$count direct dependencies, soft cap is $CAP_DIRECT_DEPS — every one is code you ship"
fi

# --- new / dropped direct dependencies vs the baseline ------------------------
baseline_present=0
if [ -f "$DEPS_BASELINE" ]; then
  baseline_present=1
  base_deps="$(grep -v '^#' "$DEPS_BASELINE" | grep -v '^[[:space:]]*$' | sort -u || true)"

  while IFS= read -r d; do
    [ -n "$d" ] || continue
    emit dep_new error go.mod "$(mod_line "$d")" "$d" \
      "new direct dependency '$d' is not in $DEPS_BASELINE — justify it, then re-run --refresh in the same commit"
  done < <(comm -23 <(printf '%s\n' "$deps") <(printf '%s\n' "$base_deps"))

  while IFS= read -r d; do
    [ -n "$d" ] || continue
    emit dep_removed note go.mod 1 "$d" \
      "direct dependency '$d' dropped since the baseline — re-run --refresh to lock the improvement in"
  done < <(comm -13 <(printf '%s\n' "$deps") <(printf '%s\n' "$base_deps"))
fi

# --- available updates (opt-in; needs the network) ----------------------------
if [ "$updates" -eq 1 ]; then
  if upd=$(go list -m -u -f '{{if and (not .Indirect) .Update}}{{.Path}} {{.Version}} {{.Update.Version}}{{end}}' all 2>/dev/null); then
    while read -r path cur new; do
      [ -n "$path" ] || continue
      emit dep_update note go.mod "$(mod_line "$path")" "$path" \
        "$path $cur -> $new available"
    done < <(printf '%s\n' "$upd" | grep -v '^[[:space:]]*$' || true)
  else
    say "  deps-status: update check unavailable (offline or proxy unreachable) — skipped."
  fi
fi

# --- report -------------------------------------------------------------------
say ""
say "  deps: $count direct (cap $CAP_DIRECT_DEPS), baseline $([ "$baseline_present" -eq 1 ] && echo "$DEPS_BASELINE" || echo 'not committed — new-dep enforcement off')"

if [ "$FINDINGS_COUNT" -eq 0 ]; then
  say "  ✓ deps-status: no findings."
  exit 0
fi

say "  deps-status: $FINDINGS_COUNT finding(s), $FINDINGS_ERRORS error(s)."
[ "$warn_only" -eq 1 ] && exit 0
[ "$FINDINGS_ERRORS" -gt 0 ] && exit 1
exit 0
