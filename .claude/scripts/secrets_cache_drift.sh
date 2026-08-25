#!/usr/bin/env bash
# secrets_cache_drift.sh — report keys that exist ONLY in the local cache and
# not in Bitwarden, while that is still harmless.
#
# Such a key is a landmine. ~/.config/secrets.env is a projection of BWS, so the
# next regeneration — triggered by something entirely unrelated, like adding a
# different secret — deletes it. The value then exists in a timestamped backup
# and nowhere else, until that backup rotates.
#
# This is not hypothetical (llm#1024): on 2026-08-25 a regen run to add
# CACHIX_AUTH_TOKEN removed SIGNAL_ACCOUNT, which had never been migrated to
# BWS. Both Signal entry points fail closed on a missing account (llm#946), so
# capture stopped — hours after that same capability had been repaired.
#
# The regen script now REFUSES to delete without --allow-removals, so the loss
# cannot recur silently. This script closes the other half: surfacing the drift
# BEFORE someone is mid-way through an unrelated task and meets a refusal they
# did not expect.
#
# Read-only. Never prints a secret value — key names only.
#
# Usage:
#   secrets_cache_drift.sh              # human-readable; exit 1 if drift found
#   secrets_cache_drift.sh --quiet      # one banner line, always exit 0
#   secrets_cache_drift.sh --selftest
#
# Exit: 0 no drift (or --quiet) · 1 drift found · 2 could not determine
#       Note 2 is distinct: "I could not ask BWS" must never read as "no drift"
#       (checks-must-distinguish-unknown, llm#1021).
#
# llm#1024

set -uo pipefail

CACHE_FILE="${SECRETS_CACHE_FILE:-$HOME/.config/secrets.env}"
BWS_BIN="${BWS_BIN:-$HOME/.cargo/bin/bws}"
KEYCHAIN_SERVICE="${BWS_KEYCHAIN_SERVICE:-claude-cron}"
KEYCHAIN_ACCOUNT="${BWS_KEYCHAIN_ACCOUNT:-bws}"
QUIET=0

while [ $# -gt 0 ]; do
  case "$1" in
    (--quiet)    QUIET=1; shift ;;
    (--selftest) SELFTEST=1; shift ;;
    (-h|--help)  echo "Usage: $(basename "$0") [--quiet] [--selftest]" >&2; exit 2 ;;
    (*)          echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
SELFTEST="${SELFTEST:-0}"

# Key names from a KEY=value file. Comments and blanks skipped. Values never read.
_key_names() {
  [ -r "$1" ] || return 0
  sed -E 's/=.*//' "$1" 2>/dev/null | grep -vE '^[[:space:]]*(#|$)' | sed -E 's/^[[:space:]]*(export[[:space:]]+)?//'
}

_bws_key_names() {
  local tok out rc
  tok="$(security find-generic-password -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null)"
  if [ -z "$tok" ]; then
    echo "INDETERMINATE: no BWS token in Keychain (service=$KEYCHAIN_SERVICE)" >&2
    return 2
  fi
  out="$(BWS_ACCESS_TOKEN="$tok" "$BWS_BIN" secret list -o env 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "INDETERMINATE: bws secret list failed (rc=$rc): $(printf '%s' "$out" | head -c 120)" >&2
    return 2
  fi
  printf '%s\n' "$out" | sed -E 's/=.*//' | grep -vE '^[[:space:]]*(#|$)'
}

run_check() {
  [ -r "$CACHE_FILE" ] || { echo "INDETERMINATE: cache not readable at $CACHE_FILE" >&2; return 2; }

  local bws_names rc
  bws_names="$(_bws_key_names)"; rc=$?
  [ "$rc" -eq 0 ] || return 2

  local drift
  drift="$(comm -23 \
      <(_key_names "$CACHE_FILE" | sort -u) \
      <(printf '%s\n' "$bws_names" | sort -u) 2>/dev/null)"

  local n
  n="$(printf '%s\n' "$drift" | grep -c . || true)"
  n="${n:-0}"

  if [ "$QUIET" -eq 1 ]; then
    if [ "$n" -gt 0 ]; then
      echo "secrets-drift: $n cache-only key(s) — will be DELETED by the next regen: $(printf '%s' "$drift" | tr '\n' ' ')"
    fi
    return 0
  fi

  if [ "$n" -eq 0 ]; then
    echo "secrets-drift: none — every cache key is backed by Bitwarden."
    return 0
  fi

  echo "secrets-drift: $n key(s) exist in the cache but NOT in Bitwarden."
  printf '  %s\n' $drift
  echo ""
  echo "  These live in $CACHE_FILE and nowhere else. The next"
  echo "  regeneration — triggered by any unrelated secret write — would delete"
  echo "  them. secrets_cache_regen.sh now refuses without --allow-removals, so"
  echo "  they are safe today, but the refusal will block whatever you are doing."
  echo ""
  echo "  Fix each now:"
  printf '      ~/.claude/scripts/bws_set_secret.sh %s\n' $drift
  return 1
}

selftest() {
  local T pass=0 fail=0
  T="$(mktemp -d)"
  ok(){ pass=$((pass+1)); echo "  PASS: $1"; }
  bad(){ fail=$((fail+1)); echo "  FAIL: $1"; }
  echo "secrets_cache_drift.sh --selftest"

  printf 'A=1\nB=2\n# comment\n\nC=3\n' > "$T/cache"
  local got
  got="$(_key_names "$T/cache" | tr '\n' ' ')"
  [ "$got" = "A B C " ] && ok "_key_names skips comments and blanks" || bad "_key_names gave '$got'"

  printf 'export D=4\n' > "$T/cache2"
  [ "$(_key_names "$T/cache2")" = "D" ] && ok "_key_names tolerates an export prefix" || bad "export prefix not stripped"

  # Values must never appear in output.
  printf 'SECRET=hunter2\n' > "$T/cache3"
  _key_names "$T/cache3" | grep -q hunter2 && bad "_key_names leaked a value" || ok "_key_names does not leak values"

  # Unreadable cache is INDETERMINATE (2), not "no drift" (0).
  CACHE_FILE="$T/nonexistent" QUIET=0
  ( CACHE_FILE="$T/nonexistent"; run_check >/dev/null 2>&1 ); local rc=$?
  [ "$rc" -eq 2 ] && ok "missing cache reports INDETERMINATE (2), not clean (0)" || bad "missing cache returned $rc"

  echo "  $pass passed, $fail failed"
  rm -rf "$T"
  [ "$fail" -eq 0 ]
}

[ "$SELFTEST" -eq 1 ] && { selftest; exit $?; }
run_check
exit $?
