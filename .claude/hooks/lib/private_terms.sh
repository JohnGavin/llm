#!/usr/bin/env bash
# private_terms.sh -- shared private-term list loading and matching (llm#1387,
# privacy layer L1; same contract as llm#1386 generator and llm#1388 scanner).
# Sourced, not executed. bash 3.2 compatible.
#
# Contract with private_terms_sync.sh: one term per line, '#' lines are comments,
# first line '# private_terms v1 generated=<ISO-8601 UTC> count=<n>', the list
# must contain the canary term. Terms are matched whole-word, case-insensitive,
# as literals.
#
#   pt_prepare   -> 0 armed (PT_FILE = normalised terms); 3 INDETERMINATE (reason
#                   on stderr, never a term value)
#   pt_match     -> stdin = content; prints matching line numbers; returns 0 when
#                   there is a match, 1 when none
#   pt_cleanup   -> removes the temp term file
#
# Env: PRIVATE_TERMS_FILE (tests/override), PRIVATE_TERMS_MAX_AGE_DAYS (default 7).
# The canary is assembled from two literals so this file never contains it.

PT_CANARY="zzcanary""privterm7q"
PT_FILE=""

_pt_epoch() {
  # $1 = ISO-8601 UTC "YYYY-MM-DDTHH:MM:SSZ"; prints epoch or nothing.
  local iso="$1" e
  e="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s 2>/dev/null)" || e=""
  if [ -z "$e" ]; then e="$(date -u -d "$iso" +%s 2>/dev/null)" || e=""; fi
  printf '%s' "$e"
}

pt_match() {
  # '_' is a word character for grep -w, so map it to a space on both sides.
  [ -n "$PT_FILE" ] || return 1
  local hits
  hits="$(tr '_' ' ' | LC_ALL=C grep -n -i -w -F -f "$PT_FILE" 2>/dev/null | cut -d: -f1)"
  if [ -z "$hits" ]; then return 1; fi
  printf '%s\n' "$hits"
  return 0
}

pt_cleanup() {
  if [ -n "$PT_FILE" ]; then rm -f "$PT_FILE"; fi
  PT_FILE=""
}

pt_prepare() {
  local f="${PRIVATE_TERMS_FILE:-$HOME/.config/private_terms.txt}"
  local max="${PRIVATE_TERMS_MAX_AGE_DAYS:-7}"
  local first gen gen_epoch now age_days
  if [ ! -r "$f" ] || [ ! -f "$f" ]; then
    echo "private-term list missing or unreadable" >&2
    return 3
  fi
  first="$(head -n 1 "$f" 2>/dev/null)"
  case "$first" in
    "# private_terms v1 "*generated=*) : ;;
    *) echo "private-term list has no '# private_terms v1 generated=...' header line" >&2; return 3 ;;
  esac
  gen="${first#*generated=}"
  gen="${gen%% *}"
  gen_epoch="$(_pt_epoch "$gen")"
  if [ -z "$gen_epoch" ]; then
    echo "private-term list header has an unparseable generated= timestamp" >&2
    return 3
  fi
  now="$(date -u +%s)"
  if [ "$gen_epoch" -gt $((now + 300)) ]; then
    echo "private-term list header generated= is in the future" >&2
    return 3
  fi
  age_days=$(( (now - gen_epoch) / 86400 ))
  if [ "$age_days" -gt "$max" ]; then
    echo "private-term list is stale (${age_days} days old, max ${max})" >&2
    return 3
  fi
  PT_FILE="$(mktemp "${TMPDIR:-/tmp}/private_term_guard.XXXXXX")" || {
    echo "cannot create a temp file for the term list" >&2
    return 3
  }
  # lowercase, strip CR, drop comments and blank lines, map '_' to ' '
  tr '[:upper:]' '[:lower:]' < "$f" | tr -d '\r' | tr '_' ' ' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | grep -v -e '^#' -e '^$' > "$PT_FILE" || true
  if [ ! -s "$PT_FILE" ]; then
    echo "private-term list has a header but no terms" >&2
    pt_cleanup
    return 3
  fi
  if ! grep -q -x -F -- "$(printf '%s' "$PT_CANARY" | tr '[:upper:]' '[:lower:]')" "$PT_FILE"; then
    echo "private-term list does not contain the canary term (truncated or wrong file?)" >&2
    pt_cleanup
    return 3
  fi
  # Liveness: the matcher must flag the canary inside a hyphenated, underscored line.
  if ! printf 'probe line a-%s_b\n' "$PT_CANARY" | pt_match >/dev/null; then
    echo "the private-term matcher did not flag its own canary; it cannot be trusted to report clean" >&2
    pt_cleanup
    return 3
  fi
  return 0
}
