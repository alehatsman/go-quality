#!/usr/bin/env bash
# lint-config-check — assert a consumer's .golangci.yml has not drifted from the
# canonical baseline shipped in this module.
#
# Why this exists: golangci-lint v2 has no config-merge. `goq/sync-config` copies
# the baseline into a consumer, and the consumer then appends its own path-bound
# `exclusions.rules`. Nothing detects that the copy has since lost a linter — a
# deleted line in `enable:` silently turns a gate off, and the guide in
# docs/GO.md starts describing checks that no longer run.
#
# Both configs are parsed by golangci-lint itself (`golangci-lint linters
# --config <path>`), not by grepping YAML, so the comparison reflects what the
# tool will actually run — including linters pulled in by `linters.default`.
#
# Enforcement, not mutation: this never rewrites the consumer's file. The fix is
# either `goq/sync-config` (take the baseline again) or an explicit local
# decision to diverge.
#
# Output (one finding per line):
#   text  (default): path:line: rule: message
#   jsonl (--format jsonl): shared gate finding schema, one object per line.
#     stdout stays pure JSONL; human status/summary go to stderr.
#
# Rules:
#   linter_missing   [error]  canonical enables it, the consumer does not
#   linter_extra     [note]   consumer enables it, the canonical does not (informational)
#   setting_drift    [error]  a load-bearing setting value differs from canonical
#   config_absent    [error]  the consumer has no .golangci.yml at all
#
# Usage:
#   bash scripts/lint-config-check.sh                    # check ./.golangci.yml
#   bash scripts/lint-config-check.sh --config path.yml  # check an explicit file
#   bash scripts/lint-config-check.sh --format jsonl     # structured findings
#   bash scripts/lint-config-check.sh --warn-only        # always exit 0
#   bash scripts/lint-config-check.sh --ci               # missing tool is fatal
set -euo pipefail

format="text"
warn_only=0
ci_mode=0
consumer=""

while [ $# -gt 0 ]; do
  case "$1" in
    --config) consumer="${2:-}"; shift 2 ;;
    --config=*) consumer="${1#*=}"; shift ;;
    --format) format="${2:-}"; shift 2 ;;
    --format=*) format="${1#*=}"; shift ;;
    --warn-only) warn_only=1; shift ;;
    --ci) ci_mode=1; shift ;;
    -h|--help) sed -n '2,35p' "$0"; exit 0 ;;
    *) echo "lint-config-check: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

case "$format" in
  text|jsonl) ;;
  *) echo "lint-config-check: unknown --format '$format' (want text|jsonl)" >&2; exit 2 ;;
esac

say() { if [ "$format" = "jsonl" ]; then echo "$@" >&2; else echo "$@"; fi; }

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANONICAL="$SCRIPTS_DIR/../.golangci.yml"

if [ ! -f "$CANONICAL" ]; then
  echo "lint-config-check: canonical config not found at $CANONICAL" >&2
  exit 2
fi

cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
consumer="${consumer:-.golangci.yml}"

if ! command -v golangci-lint >/dev/null 2>&1; then
  if [ "$ci_mode" -eq 1 ]; then
    echo "lint-config-check: golangci-lint not found — run scripts/install-tools.sh" >&2
    exit 1
  fi
  say "  lint-config-check: golangci-lint not installed — skipping."
  exit 0
fi

# --- finding emission ---------------------------------------------------------
findings=0
errors=0

json_str() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

# emit <rule> <level> <path> <line> <discriminator> <message>
emit() {
  if [ "$format" = "jsonl" ]; then
    printf '{"tool":"lint-config-check","rule":%s,"level":%s,"path":%s,"line":%s,"message":%s,"fingerprint":%s}\n' \
      "$(json_str "$1")" "$(json_str "$2")" "$(json_str "$3")" "$4" \
      "$(json_str "$6")" "$(json_str "$1:$3:$5")"
  else
    printf '%s:%s: %s: %s\n' "$3" "$4" "$1" "$6"
  fi
  findings=$((findings + 1))
  [ "$2" = "error" ] && errors=$((errors + 1))
  return 0
}

# --- the consumer must have a config at all -----------------------------------
if [ ! -f "$consumer" ]; then
  emit config_absent error "$consumer" 1 config \
    "no .golangci.yml — install the shared baseline with the goq/sync-config task"
  say ""
  say "  lint-config-check: 1 finding (config absent)."
  [ "$warn_only" -eq 1 ] && exit 0
  exit 1
fi

# --- enabled-linter sets, resolved by golangci-lint itself --------------------
# `golangci-lint linters` prints "Enabled by your configuration linters:" then
# one "name: description" line per linter, terminated by a blank line.
enabled_set() {
  golangci-lint linters --config "$1" 2>/dev/null \
    | awk '/^Enabled by your configuration linters:/{f=1;next} /^$/{f=0} f{sub(/:.*/,"");print}' \
    | sort -u
}

canon_linters="$(enabled_set "$CANONICAL")"
local_linters="$(enabled_set "$consumer")"

if [ -z "$canon_linters" ]; then
  echo "lint-config-check: could not resolve the canonical linter set — is $CANONICAL valid?" >&2
  exit 2
fi
if [ -z "$local_linters" ]; then
  emit setting_drift error "$consumer" 1 parse \
    "golangci-lint could not resolve any linters from this config — run 'golangci-lint config verify'"
  say ""
  say "  lint-config-check: 1 finding (config unparseable)."
  [ "$warn_only" -eq 1 ] && exit 0
  exit 1
fi

while IFS= read -r l; do
  [ -n "$l" ] || continue
  emit linter_missing error "$consumer" 1 "$l" \
    "canonical baseline enables '$l' but this config does not — re-sync with goq/sync-config"
done < <(comm -23 <(echo "$canon_linters") <(echo "$local_linters"))

while IFS= read -r l; do
  [ -n "$l" ] || continue
  emit linter_extra note "$consumer" 1 "$l" \
    "enables '$l' beyond the canonical baseline (fine — noted so the divergence is visible)"
done < <(comm -13 <(echo "$canon_linters") <(echo "$local_linters"))

# --- load-bearing setting values ---------------------------------------------
# Deliberately narrow. These two values are load-bearing beyond golangci-lint
# itself: the cyclomatic cap is shared with scripts/budget-status.sh and the
# structural ratchet, and `run.tests` decides whether test rules are enforced at
# all. Everything else is the consumer's business.
#
# Extracted by line match rather than a YAML parser — the fleet's shell scripts
# take no parsing dependencies. A reformatted config can therefore report drift
# it does not have; the finding names the key so that is a five-second read.
scalar_at() {  # scalar_at <file> <key>
  awk -v key="$2" '$1 == key":" { print $2; exit }' "$1"
}

for key in max-complexity tests; do
  want="$(scalar_at "$CANONICAL" "$key")"
  got="$(scalar_at "$consumer" "$key")"
  [ -n "$want" ] || continue
  if [ "$want" != "$got" ]; then
    emit setting_drift error "$consumer" 1 "$key" \
      "$key is '${got:-unset}', canonical baseline is '$want'"
  fi
done

# --- report -------------------------------------------------------------------
if [ "$findings" -eq 0 ]; then
  say "  ✓ lint-config-check: $consumer matches the canonical baseline ($(echo "$canon_linters" | wc -l | tr -d ' ') linters)."
  exit 0
fi

say ""
say "  lint-config-check: $findings finding(s), $errors error(s) in $consumer."
[ "$warn_only" -eq 1 ] && exit 0
[ "$errors" -gt 0 ] && exit 1
exit 0
