#!/usr/bin/env bash
# ai-lint — sweep Go source for patterns that AI agents commonly leave behind.
#
# Output (one finding per line):
#   text  (default): path:line: rule: message
#   jsonl (--format jsonl): a structured finding object per line —
#     {"tool":"ai-lint","rule":..,"level":"error","path":..,"line":N,
#      "message":..,"fingerprint":"rule:path:line"}
#     stdout stays pure JSONL; human status/summary go to stderr. This is the
#     shared gate finding schema (dex #155 P0) — the pilot for making every gate
#     step machine-readable. Exit code is unchanged in both modes.
#
# Rules (intentionally narrow — false positives erode trust fast):
#   stub-panic     panic("not implemented" | "unimplemented" | "TODO" | "FIXME" | "placeholder")
#   agent-todo     TODO(claude|ai|bot|gpt|assistant)  — replace with a real owner
#   ai-self-ref    comment references the agent dialog ("as requested", "per your request", …)
#   diff-relic     // REMOVED: / // PREVIOUSLY: uppercase banners — belongs in commit history
#
# Rules considered and dropped (kept here so we don't re-introduce them naively):
#   diff-relic lowercase ("// previously", "// removed") — too noisy: legitimate prose
#     in CLI tools and package handlers ("the list of packages removed",
#     "previously only DurationMs was carried") trips it. Uppercase-only is safe.
#   the-user-asked — "the user" in a CLI tool refers to the end user, not
#     the agent's interlocutor. Real AI-tell requires an explicit pronoun.
#
# Usage:
#   bash scripts/ai-lint.sh                # scan staged Go files (pre-commit mode)
#   bash scripts/ai-lint.sh --all          # scan every tracked Go file
#   bash scripts/ai-lint.sh --warn-only    # always exit 0, just report
#   bash scripts/ai-lint.sh --format jsonl # emit structured findings (JSONL) on stdout
#   bash scripts/ai-lint.sh path/file.go   # scan explicit files
set -euo pipefail

mode="staged"
warn_only=0
format="text"
explicit=()
while [ $# -gt 0 ]; do
  case "$1" in
    --all) mode="all"; shift ;;
    --warn-only) warn_only=1; shift ;;
    --format) format="${2:-}"; shift 2 ;;
    --format=*) format="${1#*=}"; shift ;;
    -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
    --) shift; explicit+=("$@"); break ;;
    *)  explicit+=("$1"); shift ;;
  esac
done

case "$format" in
  text|jsonl) ;;
  *) echo "ai-lint: unknown --format '$format' (want text|jsonl)" >&2; exit 2 ;;
esac

# In jsonl mode stdout must stay pure JSONL, so human status/summary go to
# stderr. `say` centralizes that routing (text mode: stdout as before).
say() { if [ "$format" = "jsonl" ]; then echo "$@" >&2; else echo "$@"; fi; }

cd "$(git rev-parse --show-toplevel)"

# --- file list ----------------------------------------------------------------
raw=()
if [ "${#explicit[@]}" -gt 0 ]; then
  raw=("${explicit[@]}")
elif [ "$mode" = "all" ]; then
  while IFS= read -r f; do raw+=("$f"); done < <(git ls-files -- '*.go')
else
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    raw+=("$f")
  done < <(git diff --cached --name-only --diff-filter=ACMR -- '*.go')
fi

files=()
for f in "${raw[@]+"${raw[@]}"}"; do
  case "$f" in
    vendor/*|*/vendor/*|*.pb.go|*_generated.go|*_gen.go) continue ;;
  esac
  if [ -f "$f" ] && head -5 "$f" 2>/dev/null | grep -q '^// Code generated'; then
    continue
  fi
  files+=("$f")
done

if [ "${#files[@]}" -eq 0 ]; then
  say "  ai-lint: no Go files to scan."
  exit 0
fi

# --- rules --------------------------------------------------------------------
# run_rule <name> <egrep-pattern> <message> [scope: all|non-test]
findings=0

# json_str — emit a JSON-escaped double-quoted string for arbitrary text.
# Handles the two bytes that can appear in a path/message and break JSON: the
# backslash and the double-quote. Messages are static and paths are Go source
# files, so no control chars are in play; keep it boring.
json_str() {
  local s="$1"
  s="${s//\\/\\\\}"   # \ -> \\   (must run first)
  s="${s//\"/\\\"}"   # " -> \"
  printf '"%s"' "$s"
}

emit() {  # path lineno rule message  (all rules here are gate-failing -> level error)
  if [ "$format" = "jsonl" ]; then
    printf '{"tool":"ai-lint","rule":%s,"level":"error","path":%s,"line":%s,"message":%s,"fingerprint":%s}\n' \
      "$(json_str "$3")" "$(json_str "$1")" "$2" "$(json_str "$4")" "$(json_str "$3:$1:$2")"
  else
    printf '%s:%s: %s: %s\n' "$1" "$2" "$3" "$4"
  fi
  findings=$((findings + 1))
}

run_rule() {
  local name="$1" pattern="$2" message="$3" scope="${4:-all}" f match loc lineno
  for f in "${files[@]}"; do
    if [ "$scope" = "non-test" ] && [[ "$f" == *_test.go ]]; then continue; fi
    while IFS= read -r match; do
      [ -z "$match" ] && continue
      loc="${match%%:*}"
      rest="${match#*:}"
      lineno="${rest%%:*}"
      emit "$loc" "$lineno" "$name" "$message"
    done < <(grep -nHE "$pattern" "$f" 2>/dev/null || true)
  done
}

run_rule stub-panic \
  'panic\("(not implemented|unimplemented|TODO|FIXME|placeholder)' \
  'stub panic — finish or remove the function before committing' \
  non-test

run_rule agent-todo \
  '(TODO|FIXME|XXX)\((claude|ai|bot|gpt|assistant)\b' \
  'agent-tagged TODO — replace with a real owner or open an issue'

run_rule ai-self-ref \
  '//.*\b(as requested|per your request|as you (asked|requested|wanted)|in response to your request)\b' \
  'AI prompt artifact — comment references the agent dialog'

run_rule diff-relic \
  '//[[:space:]]*(REMOVED|PREVIOUSLY):[[:space:]]' \
  'diff relic — uppercase removal banner belongs in commit history, not source'

# --- report -------------------------------------------------------------------
if [ "$findings" -eq 0 ]; then
  say "  ✓ ai-lint: no AI-smell findings in ${#files[@]} file(s)."
  exit 0
fi

say ""
say "  ai-lint: $findings finding(s) in ${#files[@]} file(s)."
[ "$warn_only" -eq 1 ] && exit 0
exit 1
