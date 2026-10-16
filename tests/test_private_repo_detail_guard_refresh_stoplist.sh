#!/usr/bin/env bash
# Tests for llm#1348 (stale candidate list is refreshed, never silently passed)
# and llm#1213 (ordinary English words are not bare scan terms) in
# .claude/hooks/private_repo_detail_guard.sh.
#
# Synthetic names only. Every key assertion is paired with a FALSIFICATION that
# flips the condition and must produce the opposite verdict (the check can go
# red). Exit 0 all pass, 1 any failure.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${PRDG_HOOK:-$ROOT/.claude/hooks/private_repo_detail_guard.sh}"   # override = red-first runs
STOPLIST="$ROOT/.claude/scripts/private_name_stoplist.txt"
TMP="$(mktemp -d /tmp/prdg_refresh_stoplist.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
TOTAL=0
ok()   { TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1)); echo "PASS  $1"; }
bad()  { TOTAL=$((TOTAL + 1)); echo "FAIL  $1"; }
expect() { # expect WANT GOT DESC
  if [ "$1" = "$2" ]; then ok "$3 (=$2)"; else bad "$3 (want '$1', got '$2')"; fi
}

# Stub repo_visibility.sh: classify -> public; candidates -> $STUB/cands.tsv,
# exit 3 when $STUB/stale exists; candidates --refresh -> recorded call.
STUB="$TMP/stub"
mkdir -p "$STUB" "$TMP/logs"
cat > "$TMP/rv_stub.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  classify) printf 'public'; exit 0 ;;
  candidates)
    if [ "${2:-}" = "--refresh" ]; then echo "refresh" >> "$STUB/refresh_calls"; exit 0; fi
    if [ -f "$STUB/stale" ]; then echo "stub: INDETERMINATE stale" >&2; exit 3; fi
    cat "$STUB/cands.tsv"; exit 0 ;;
esac
exit 2
EOF
chmod +x "$TMP/rv_stub.sh"

# run_hook BODY [ENV=VAL ...]  -> sets RC and ERR
run_hook() {
  local body="$1"; shift
  local cmd payload
  cmd="gh issue create --repo fake-owner/fake-public --title t --body \"$body\""
  payload="$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$cmd")"
  RC=0
  printf '%s' "$payload" | env STUB="$STUB" \
    PRIVATE_DETAIL_REPO_VISIBILITY_SCRIPT="$TMP/rv_stub.sh" \
    PRIVATE_DETAIL_LOG_DIR="$TMP/logs" "$@" \
    bash "$HOOK" >/dev/null 2>"$TMP/err" || RC=$?
  ERR="$(cat "$TMP/err")"
}
verdict() { if [ "$RC" -eq 2 ]; then echo BLOCK; else echo ALLOW; fi; }

echo "== #1213: common words vs real names =="
rm -f "$STUB/stale" "$STUB/refresh_calls"
printf 'zzfakeprojname\t%s/fake/zzfakeprojname\tprivate\n' "$TMP" > "$STUB/cands.tsv"
printf 'knowledge\t%s/fake/knowledge\tprivate\n' "$TMP" >> "$STUB/cands.tsv"

run_hook "see zzfakeprojname for detail" PRIVATE_DETAIL_NO_REFRESH_KICK=1
expect BLOCK "$(verdict)" "real (synthetic) private name is blocked"

run_hook "an ordinary note about knowledge in prose" PRIVATE_DETAIL_NO_REFRESH_KICK=1
expect ALLOW "$(verdict)" "common English word that is a discovered name is allowed"

# Falsification: without the stoplist the same text MUST block (the ALLOW above
# is caused by the stoplist, not by the matcher being inert).
run_hook "an ordinary note about knowledge in prose" PRIVATE_DETAIL_NO_REFRESH_KICK=1 \
  PRIVATE_DETAIL_STOPLIST_FILE=/nonexistent/stoplist.txt
expect BLOCK "$(verdict)" "falsification: stoplist removed -> same text blocks"

# Falsification: empty candidate list -> real name no longer blocks.
cp "$STUB/cands.tsv" "$TMP/cands.keep"
: > "$STUB/cands.tsv"
run_hook "see zzfakeprojname for detail" PRIVATE_DETAIL_NO_REFRESH_KICK=1
expect ALLOW "$(verdict)" "falsification: candidate removed -> real name text allowed"
cp "$TMP/cands.keep" "$STUB/cands.tsv"

run_hook "files live under $TMP/fake/knowledge/notes" PRIVATE_DETAIL_NO_REFRESH_KICK=1
expect BLOCK "$(verdict)" "path of a stoplisted-name candidate still blocks"

printf 'knowledge\t\tconfidential_by_policy\n' > "$STUB/cands.tsv"
run_hook "an ordinary note about knowledge in prose" PRIVATE_DETAIL_NO_REFRESH_KICK=1
expect BLOCK "$(verdict)" "DECLARED name is never stoplisted"
cp "$TMP/cands.keep" "$STUB/cands.tsv"

if grep -q '^knowledge$' "$STOPLIST"; then ok "stoplist file carries the word used above"; else bad "stoplist file missing the fixture word"; fi

echo "== #1348: stale list triggers one bounded background refresh =="
touch "$STUB/stale"
rm -f "$STUB/refresh_calls" "$TMP/logs/private_repo_detail_guard.refresh_kick.epoch"
run_hook "nothing sensitive"
expect BLOCK "$(verdict)" "stale list still BLOCKS (never silently passes)"
n=0
while [ "$n" -lt 30 ] && [ ! -s "$STUB/refresh_calls" ]; do sleep 0.2; n=$((n + 1)); done
expect 1 "$(wc -l < "$STUB/refresh_calls" 2>/dev/null | tr -d ' ')" "background 'candidates --refresh' was started once"
case "$ERR" in *"background refresh"*) ok "block message says a refresh was started" ;; *) bad "block message does not mention the refresh: $ERR" ;; esac

run_hook "nothing sensitive"
sleep 1
expect BLOCK "$(verdict)" "second call inside the window still blocks"
expect 1 "$(wc -l < "$STUB/refresh_calls" | tr -d ' ')" "no second refresh inside the rate-limit window"

# Falsification: kick disabled -> refresh never called.
rm -f "$STUB/refresh_calls" "$TMP/logs/private_repo_detail_guard.refresh_kick.epoch"
run_hook "nothing sensitive" PRIVATE_DETAIL_NO_REFRESH_KICK=1
sleep 1
expect BLOCK "$(verdict)" "kick disabled: still blocks"
expect 0 "$( [ -f "$STUB/refresh_calls" ] && wc -l < "$STUB/refresh_calls" | tr -d ' ' || echo 0 )" "falsification: kick disabled -> no refresh started"

# Refreshed (fresh) list -> allowed again, proving the block was staleness only.
rm -f "$STUB/stale"
run_hook "nothing sensitive" PRIVATE_DETAIL_NO_REFRESH_KICK=1
expect ALLOW "$(verdict)" "fresh list + unrelated body -> allowed (block was due to staleness only)"

echo ""
echo "test_private_repo_detail_guard_refresh_stoplist: $PASS/$TOTAL PASS"
[ "$PASS" -eq "$TOTAL" ] && exit 0
exit 1
