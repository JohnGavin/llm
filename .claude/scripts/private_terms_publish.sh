#!/usr/bin/env bash
# private_terms_publish.sh -- keep the L3 CI secrets in step with the local
# private-term list (llm#1389, parent llm#1382). bash 3.2 compatible.
#
# The CI check private-term-hash-check compares added lines to salted HMAC
# digests held in two Actions secrets, PRIVATE_TERMS_SALT and
# PRIVATE_TERM_HASHES. This job re-publishes both whenever the TERMS change,
# so the owner no longer runs private_terms_hashes.sh and `gh secret set` by
# hand.
#
# Usage: private_terms_publish.sh [--apply] [--repo OWNER/REPO]
#   default is a DRY RUN: validates the list and compares fingerprints, sets
#   nothing and calls gh not at all. Default repo JohnGavin/llm.
#
# Fingerprint: sha256 of the sorted list EXCLUDING the '# private_terms v1
# generated=' header, so the daily sync that changes no term does not trigger.
# State file: ~/.claude/state/private_terms_published.sha
#   (env PRIVATE_TERMS_PUBLISH_STATE). Written ONLY after both secrets were
#   set and their updatedAt moved.
#
# Secret values go to gh on stdin from 0600 files in a private mktemp -d that
# is removed on every exit path. They are never in argv, env, stdout, stderr
# or the log. Only counts and an 8-char fingerprint prefix are printed.
#
# Env: PRIVATE_TERMS_FILE (list), PRIVATE_TERMS_PUBLISH_GH (gh replacement,
#      tests), PRIVATE_TERMS_PUBLISH_STATE, PRIVATE_TERMS_PUBLISH_LOG.
#
# Exit: 0 ok / current, 2 usage, 3 INDETERMINATE (list missing/stale/no
# canary, openssl or gh missing, set or verify failed).

set -uo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/../hooks/lib/private_terms.sh"

APPLY=0
REPO="JohnGavin/llm"
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    *) echo "usage: private_terms_publish.sh [--apply] [--repo OWNER/REPO]" >&2; exit 2 ;;
  esac
done
case "$REPO" in
  */*) : ;;
  *) echo "usage: --repo needs OWNER/REPO" >&2; exit 2 ;;
esac

GH="${PRIVATE_TERMS_PUBLISH_GH:-gh}"
STATE="${PRIVATE_TERMS_PUBLISH_STATE:-$HOME/.claude/state/private_terms_published.sha}"
LOG="${PRIVATE_TERMS_PUBLISH_LOG:-$HOME/.claude/logs/private_terms_publish.log}"
LIST="${PRIVATE_TERMS_FILE:-$HOME/.config/private_terms.txt}"

WORK=""
cleanup() {
  if [ -n "$WORK" ]; then rm -rf "$WORK"; fi
  pt_cleanup
}
trap cleanup EXIT
trap 'exit 3' INT TERM

indeterminate() {
  echo "INDETERMINATE: $1" >&2
  exit 3
}

# Validates header, freshness (max age), terms and canary; never prints a term.
pt_prepare || indeterminate "private-term list unusable (see reason above)"

if ! command -v openssl >/dev/null 2>&1; then
  indeterminate "openssl not found"
fi

FP="$(LC_ALL=C grep -v '^# private_terms v1 generated=' "$LIST" | LC_ALL=C sort | openssl dgst -sha256)" \
  || indeterminate "could not fingerprint the list"
FP="${FP##* }"
[ -n "$FP" ] || indeterminate "empty fingerprint"
FP8="$(printf '%s' "$FP" | cut -c1-8)"

OLD=""
if [ -r "$STATE" ]; then OLD="$(head -n 1 "$STATE" 2>/dev/null)"; fi
if [ "$OLD" = "$FP" ]; then
  echo "current (fingerprint $FP8)"
  exit 0
fi

if [ "$APPLY" -ne 1 ]; then
  echo "dry run: digests would be republished to $REPO (fingerprint $FP8); pass --apply"
  exit 0
fi

if ! command -v "$GH" >/dev/null 2>&1; then
  indeterminate "gh not found"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pt_publish.XXXXXX")" || indeterminate "cannot create a temp dir"
chmod 700 "$WORK"

bash "$SCRIPT_DIR/private_terms_hashes.sh" --out-dir "$WORK/out" --repo "$REPO" >/dev/null \
  || indeterminate "digest generation failed"
SALT_F="$WORK/out/salt.txt"
HASH_F="$WORK/out/hashes.txt"
if [ ! -s "$SALT_F" ] || [ ! -s "$HASH_F" ]; then
  indeterminate "digest generation produced empty output"
fi
NTERMS=$(( $(wc -l < "$HASH_F" | tr -d ' ') - 1 ))

# updated_at NAME -> prints updatedAt for that secret ('' if absent); rc 1 on gh failure
updated_at() {
  local json
  json="$("$GH" secret list --repo "$REPO" --json name,updatedAt 2>/dev/null)" || return 1
  printf '%s' "$json" | tr '{' '\n' | grep "\"name\":\"$1\"" \
    | sed -n 's/.*"updatedAt":"\([^"]*\)".*/\1/p' | head -n 1
  return 0
}

B_HASH="$(updated_at PRIVATE_TERM_HASHES)" || indeterminate "gh secret list failed (before)"
B_SALT="$(updated_at PRIVATE_TERMS_SALT)" || indeterminate "gh secret list failed (before)"

logline() {
  mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
  printf 'DESTRUCTIVE: overwrite secret %s repo=%s fingerprint=%s at=%s\n' \
    "$1" "$REPO" "$FP8" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG" 2>/dev/null || true
}

logline PRIVATE_TERM_HASHES
"$GH" secret set PRIVATE_TERM_HASHES --repo "$REPO" < "$HASH_F" >/dev/null 2>&1 \
  || indeterminate "gh secret set PRIVATE_TERM_HASHES failed"
logline PRIVATE_TERMS_SALT
"$GH" secret set PRIVATE_TERMS_SALT --repo "$REPO" < "$SALT_F" >/dev/null 2>&1 \
  || indeterminate "gh secret set PRIVATE_TERMS_SALT failed (hash secret already replaced; CI check will be INDETERMINATE until a re-run)"

A_HASH="$(updated_at PRIVATE_TERM_HASHES)" || indeterminate "gh secret list failed (after)"
A_SALT="$(updated_at PRIVATE_TERMS_SALT)" || indeterminate "gh secret list failed (after)"
if [ -z "$A_HASH" ] || [ "$A_HASH" = "$B_HASH" ]; then
  indeterminate "PRIVATE_TERM_HASHES updatedAt did not move; publication not verified"
fi
if [ -z "$A_SALT" ] || [ "$A_SALT" = "$B_SALT" ]; then
  indeterminate "PRIVATE_TERMS_SALT updatedAt did not move; publication not verified"
fi

mkdir -p "$(dirname "$STATE")" || indeterminate "cannot create the state dir"
printf '%s\n' "$FP" > "$STATE.tmp.$$" && mv "$STATE.tmp.$$" "$STATE" \
  || indeterminate "cannot write the state file"

echo "digests refreshed to $NTERMS terms (fingerprint $FP8)"
exit 0
