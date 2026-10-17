#!/usr/bin/env bash
# private_term_hash_scan.sh -- CI side of privacy layer L3 (llm#1389).
#
# Hashes the tokens (and n-grams) of the ADDED lines of a diff and compares
# them with salted HMAC digests of the private terms, so a public repo can
# catch private terms without the terms being published.
#
# Usage: private_term_hash_scan.sh --base <sha> --head <sha> [--repo-dir DIR]
# Env:   PRIVATE_TERMS_SALT, PRIVATE_TERM_HASHES (secret payloads, produced by
#        private_terms_hashes.sh), optional PR_FROM_FORK=true (message only).
#
# Exit: 0 clean | 1 finding | 2 usage | 3 INDETERMINATE (missing/empty secret,
#       payload without the canary hash, malformed payload, bad diff range, or
#       a tokeniser that cannot flag its own canary). INDETERMINATE is NEVER a
#       pass (checks-must-distinguish-unknown).
# Output: rule name and file:line only; never the matched text or any term.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/private_term_hash_lib.sh"

RULE="private-term-hash"
BASE=""
HEAD=""
REPO_DIR="."
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="${2:-}"; shift 2 ;;
    --head) HEAD="${2:-}"; shift 2 ;;
    --repo-dir) REPO_DIR="${2:-}"; shift 2 ;;
    *) echo "usage: private_term_hash_scan.sh --base <sha> --head <sha> [--repo-dir DIR]" >&2; exit 2 ;;
  esac
done
if [ -z "$BASE" ] || [ -z "$HEAD" ]; then
  echo "usage: private_term_hash_scan.sh --base <sha> --head <sha> [--repo-dir DIR]" >&2
  exit 2
fi

indeterminate() {
  echo "$RULE: INDETERMINATE - $1" >&2
  exit 3
}

SALT="${PRIVATE_TERMS_SALT:-}"
PAYLOAD="${PRIVATE_TERM_HASHES:-}"
# strip whitespace/newlines a secret may carry
SALT="$(printf '%s' "$SALT" | tr -d '[:space:]')"
if [ -z "$SALT" ] || [ -z "$(printf '%s' "$PAYLOAD" | tr -d '[:space:]')" ]; then
  if [ "${PR_FROM_FORK:-}" = "true" ]; then
    indeterminate "secrets are not available to PRs from forks; the check cannot run, so it fails rather than passing unscanned"
  fi
  indeterminate "PRIVATE_TERMS_SALT and/or PRIVATE_TERM_HASHES are missing or empty; the owner has not set the secrets (see private_terms_hashes.sh)"
fi
if ! command -v openssl >/dev/null 2>&1; then
  indeterminate "openssl not found"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pth_scan.XXXXXX")" || indeterminate "cannot create a temp dir"
trap 'rm -rf "$WORK"' EXIT

printf '%s\n' "$PAYLOAD" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$' > "$WORK/payload" || true
FIRST="$(head -n 1 "$WORK/payload")"
MAXTOK="${FIRST#maxtokens=}"
if [ "$MAXTOK" = "$FIRST" ] || ! printf '%s' "$MAXTOK" | grep -q -E '^[0-9]+$'; then
  indeterminate "hash payload has no 'maxtokens=N' first line"
fi
if [ "$MAXTOK" -lt 1 ] || [ "$MAXTOK" -gt "$PTH_MAX_TOKENS_LIMIT" ]; then
  indeterminate "hash payload maxtokens is outside 1..$PTH_MAX_TOKENS_LIMIT"
fi
tail -n +2 "$WORK/payload" | grep -E '^[0-9a-f]{64}$' > "$WORK/hashes" || true
if [ ! -s "$WORK/hashes" ]; then
  indeterminate "hash payload contains no digests"
fi

CANARY_H="$(pth_hmac "$SALT" "$PTH_CANARY")" || indeterminate "HMAC computation failed"
if ! grep -q -x -F -- "$CANARY_H" "$WORK/hashes"; then
  indeterminate "hash payload lacks the canary digest (wrong salt, truncated or wrong secret)"
fi

# Liveness: the tokeniser must surface the canary from a hyphenated/underscored line.
printf 'probe\tline a-%s_b\n' "$PTH_CANARY" | pth_ngrams "$MAXTOK" | cut -f2 > "$WORK/probe"
if ! grep -q -x -F -- "$PTH_CANARY" "$WORK/probe"; then
  indeterminate "the tokeniser did not surface its own canary; it cannot be trusted to report clean"
fi

# Added lines only: "file:line<TAB>text". Header lines ("+++ b/x") are only
# honoured before the first hunk of each file, so an added line that starts
# with "++ " is still content.
git -C "$REPO_DIR" -c core.quotepath=false diff --no-ext-diff --no-textconv --no-color -U0 "$BASE...$HEAD" > "$WORK/diff" 2> "$WORK/diff.err"
if [ $? -ne 0 ]; then
  indeterminate "git diff failed for the given range"
fi
LC_ALL=C awk '
  /^diff --git / { inhdr = 1; file = ""; next }
  inhdr && /^\+\+\+ / {
    f = substr($0, 5)
    sub(/\t.*$/, "", f)
    if (f == "/dev/null") file = ""; else { sub(/^b\//, "", f); file = f }
    next
  }
  /^@@ / {
    inhdr = 0
    if (match($0, /\+[0-9]+/)) ln = substr($0, RSTART + 1, RLENGTH - 1) + 0
    next
  }
  !inhdr && file != "" && /^\+/ { print file ":" ln "\t" substr($0, 2); ln++ }
' "$WORK/diff" > "$WORK/added.tsv"

if [ ! -s "$WORK/added.tsv" ]; then
  echo "$RULE: clean - no added lines in the range"
  exit 0
fi

pth_ngrams "$MAXTOK" < "$WORK/added.tsv" > "$WORK/ngrams.tsv"
cut -f2 "$WORK/ngrams.tsv" | sort -u > "$WORK/uniq.txt"

# hash every distinct n-gram once: "hex<TAB>ngram"
while IFS= read -r g; do
  [ -n "$g" ] || continue
  h="$(pth_hmac "$SALT" "$g")" || indeterminate "HMAC computation failed"
  [ -n "$h" ] || indeterminate "HMAC returned nothing"
  printf '%s\t%s\n' "$h" "$g"
done < "$WORK/uniq.txt" > "$WORK/hashmap.tsv"

# n-grams whose digest is in the payload (kept in a file, never printed)
awk -F'\t' 'FNR == NR { h[$1] = 1; next } ($1 in h) { print $2 }' "$WORK/hashes" "$WORK/hashmap.tsv" | sort -u > "$WORK/matched.txt"

if [ ! -s "$WORK/matched.txt" ]; then
  echo "$RULE: clean - $(wc -l < "$WORK/added.tsv" | tr -d ' ') added line(s) scanned"
  exit 0
fi

awk -F'\t' 'FNR == NR { m[$1] = 1; next } ($2 in m) { print $1 }' "$WORK/matched.txt" "$WORK/ngrams.tsv" | sort -u > "$WORK/where.txt"
echo "$RULE: FINDING - an added line contains a private term (rule: $RULE; matched text withheld)" >&2
while IFS= read -r loc; do
  echo "  $loc  rule=$RULE" >&2
done < "$WORK/where.txt"
exit 1
