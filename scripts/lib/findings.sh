#!/usr/bin/env bash
# findings.sh — the shared gate finding schema, in one place.
#
# Sourced, never executed. Every bash emitter in this module uses it so that a
# change to the schema is a change to this file, not a four-file edit that
# misses one.
#
# The schema (also documented in README.md):
#
#   {"tool":…,"rule":…,"level":"error|warning|note","path":…,"line":N,
#    "message":…,"fingerprint":"rule:path:discriminator"}
#
# `level:error` = gate-failing. Under `--format jsonl` stdout must stay pure
# JSONL, so all human status goes to stderr — that is what `say` is for.
#
# The fingerprint's third component is a *discriminator*, not always the line:
# it is whatever makes the finding unique and stable across runs. A module path,
# a linter name, and the literal "total" are all used. Two findings that mean
# the same thing must produce the same fingerprint on every run, or cross-run
# dedup breaks.
#
# Usage:
#
#   SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck source=lib/findings.sh
#   . "$SCRIPTS_DIR/lib/findings.sh"
#   ...parse args into $format...
#   findings_init <tool> "$format" <progname>
#   emit <rule> <level> <path> <line> <discriminator> <message>
#   say "  human status line"
#   ... $FINDINGS_COUNT / $FINDINGS_ERRORS for the summary ...
#
# NOT used by budget-status.sh, dupl-report.sh or structure-ratchet.sh: those
# three emit their JSONL from an embedded python3 block, so a bash helper cannot
# reach them. They carry the schema independently — keep them in step by hand.

FINDINGS_TOOL=""
FINDINGS_FORMAT="text"
FINDINGS_PROG=""
FINDINGS_COUNT=0
FINDINGS_ERRORS=0

# findings_init <tool> <format> <progname>
#   tool     — the "tool" field in every finding this script emits
#   format   — text|jsonl, validated here so no caller has to
#   progname — how this script names itself in error messages
findings_init() {
  FINDINGS_TOOL="$1"
  FINDINGS_FORMAT="${2:-text}"
  FINDINGS_PROG="${3:-$1}"
  case "$FINDINGS_FORMAT" in
    text | jsonl) ;;
    *)
      echo "$FINDINGS_PROG: unknown --format '$FINDINGS_FORMAT' (want text|jsonl)" >&2
      exit 2
      ;;
  esac
}

# say — human status. stdout in text mode; stderr in jsonl mode so the findings
# stream on stdout stays machine-readable.
say() {
  if [ "$FINDINGS_FORMAT" = "jsonl" ]; then echo "$@" >&2; else echo "$@"; fi
}

# json_str — JSON-escape arbitrary text into a quoted string. Handles the two
# bytes that can appear in a path or message and break JSON: the backslash and
# the double quote. Messages are static and paths are file paths, so no control
# characters are in play; keep it boring.
json_str() {
  local s="$1"
  s="${s//\\/\\\\}" # \ -> \\   (must run first)
  s="${s//\"/\\\"}" # " -> \"
  printf '"%s"' "$s"
}

# emit <rule> <level> <path> <line> <discriminator> <message>
emit() {
  if [ "$FINDINGS_FORMAT" = "jsonl" ]; then
    printf '{"tool":%s,"rule":%s,"level":%s,"path":%s,"line":%s,"message":%s,"fingerprint":%s}\n' \
      "$(json_str "$FINDINGS_TOOL")" "$(json_str "$1")" "$(json_str "$2")" \
      "$(json_str "$3")" "$4" "$(json_str "$6")" "$(json_str "$1:$3:$5")"
  else
    printf '%s:%s: %s: %s\n' "$3" "$4" "$1" "$6"
  fi
  FINDINGS_COUNT=$((FINDINGS_COUNT + 1))
  [ "$2" = "error" ] && FINDINGS_ERRORS=$((FINDINGS_ERRORS + 1))
  # Explicit: the test above is the last command and returns 1 for any non-error
  # level, which `set -e` in the caller would treat as a failure.
  return 0
}
