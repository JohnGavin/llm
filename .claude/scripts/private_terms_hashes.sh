#!/usr/bin/env bash
# private_terms_hashes.sh -- OWNER-RUN helper for privacy layer L3 (llm#1389).
#
# Turns the local private-term list into two secret payloads for a public
# repo's Actions secrets, so CI can catch private terms without the terms ever
# being published:
#   PRIVATE_TERMS_SALT   a fresh random per-publication salt (hex)
#   PRIVATE_TERM_HASHES  line 1 'maxtokens=N', then one HMAC-SHA256(salt, term)
#                        hex digest per term (canary included), sorted
# The CI scanner is private_term_hash_scan.sh; normalisation is shared via
# lib/private_term_hash_lib.sh. Multi-token terms: the term is hashed as its
# tokens joined by a single space; the scanner tries n-grams up to N, the
# largest token count in the list, which travels in the payload.
#
# Usage: private_terms_hashes.sh --out-dir DIR [--repo OWNER/REPO]
# Writes DIR/salt.txt and DIR/hashes.txt (mode 600) and PRINTS (does not run)
# the two `gh secret set` commands. Never prints a term. Re-run (new salt)
# whenever the list changes; the old secrets then stop matching, by design.
#
# Exit: 0 ok, 2 usage, 3 INDETERMINATE (list unusable / openssl missing).

set -uo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/../hooks/lib/private_terms.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/private_term_hash_lib.sh"

OUT_DIR=""
REPO="OWNER/REPO"
while [ $# -gt 0 ]; do
  case "$1" in
    --out-dir) OUT_DIR="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    *) echo "usage: private_terms_hashes.sh --out-dir DIR [--repo OWNER/REPO]" >&2; exit 2 ;;
  esac
done
if [ -z "$OUT_DIR" ]; then
  echo "usage: private_terms_hashes.sh --out-dir DIR [--repo OWNER/REPO]" >&2
  exit 2
fi
if ! command -v openssl >/dev/null 2>&1; then
  echo "openssl not found; cannot compute HMACs" >&2
  exit 3
fi

pt_prepare || exit 3
mkdir -p "$OUT_DIR" || { echo "cannot create the out dir" >&2; exit 3; }

TERMS_TMP="$(mktemp "${TMPDIR:-/tmp}/pth_terms.XXXXXX")" || exit 3
trap 'rm -f "$TERMS_TMP"; pt_cleanup' EXIT

pth_normalise < "$PT_FILE" | grep -v '^$' | sort -u > "$TERMS_TMP" || true
if [ ! -s "$TERMS_TMP" ]; then
  echo "no usable terms after normalisation" >&2
  exit 3
fi
MAXTOK="$(awk 'NF > m { m = NF } END { print m + 0 }' "$TERMS_TMP")"
if [ "$MAXTOK" -lt 1 ] || [ "$MAXTOK" -gt "$PTH_MAX_TOKENS_LIMIT" ]; then
  echo "longest term has $MAXTOK tokens; supported range is 1..$PTH_MAX_TOKENS_LIMIT" >&2
  exit 3
fi

SALT="$(openssl rand -hex 16)" || { echo "openssl rand failed" >&2; exit 3; }
[ -n "$SALT" ] || { echo "empty salt" >&2; exit 3; }

SALT_FILE="$OUT_DIR/salt.txt"
HASH_FILE="$OUT_DIR/hashes.txt"
BODY_TMP="$(mktemp "${TMPDIR:-/tmp}/pth_body.XXXXXX")" || exit 3
trap 'rm -f "$TERMS_TMP" "$BODY_TMP"; pt_cleanup' EXIT

COUNT=0
while IFS= read -r term; do
  [ -n "$term" ] || continue
  h="$(pth_hmac "$SALT" "$term")" || { echo "HMAC failed" >&2; exit 3; }
  [ -n "$h" ] || { echo "HMAC returned nothing" >&2; exit 3; }
  printf '%s\n' "$h" >> "$BODY_TMP"
  COUNT=$((COUNT + 1))
done < "$TERMS_TMP"

{
  printf 'maxtokens=%s\n' "$MAXTOK"
  sort -u "$BODY_TMP"
} > "$HASH_FILE"
printf '%s' "$SALT" > "$SALT_FILE"
chmod 600 "$SALT_FILE" "$HASH_FILE"

echo "wrote $COUNT hashed terms (maxtokens=$MAXTOK) to:"
echo "  $SALT_FILE"
echo "  $HASH_FILE"
echo
echo "OWNER steps (nothing below has been run):"
echo "  gh secret set PRIVATE_TERMS_SALT --repo $REPO < $SALT_FILE"
echo "  gh secret set PRIVATE_TERM_HASHES --repo $REPO < $HASH_FILE"
echo "Then delete the two files (shred or rm) and add the check"
echo "'private-term-hash-check' as a required status check on main."
exit 0
