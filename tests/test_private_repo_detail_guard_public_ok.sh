#!/usr/bin/env bash
# Tests for the owner-cleared names file in .claude/hooks/private_repo_detail_guard.sh:
# ${PRIVATE_NAMES_PUBLIC_OK_FILE:-$HOME/.config/private_names_public_ok.txt}
# (llm#1382) must exempt a DISCOVERED candidate's bare NAME, and nothing else.
#
# Synthetic names only; the real file is never read (the env var always points
# at a temp file). Each exemption assertion is paired with a falsification that
# flips the condition and must produce the opposite verdict. Exit 0 all pass,
# 1 any failure.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${PRDG_HOOK:-$ROOT/.claude/hooks/private_repo_detail_guard.sh}"   # override = red-first runs
TMP="$(mktemp -d /tmp/prdg_public_ok.XXXXXX)"
trap 'chmod 600 "$TMP"/ok_* 2>/dev/null; rm -rf "$TMP"' EXIT

# The sync script's canary term, built from fragments so this file never carries
# the literal (the private-term write gate treats the canary as a term).
CANARY="zzcanary""privterm7q"

PASS=0
TOTAL=0
ok()   { TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1)); echo "PASS  $1"; }
bad()  { TOTAL=$((TOTAL + 1)); echo "FAIL  $1"; }
expect() { # expect WANT GOT DESC
  if [ "$1" = "$2" ]; then ok "$3 (=$2)"; else bad "$3 (want '$1', got '$2')"; fi
}

STUB="$TMP/stub"
mkdir -p "$STUB" "$TMP/logs"
cat > "$TMP/rv_stub.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  classify) printf 'public'; exit 0 ;;
  candidates) cat "$STUB/cands.tsv"; exit 0 ;;
esac
exit 2
EOF
chmod +x "$TMP/rv_stub.sh"

# run_hook BODY OKFILE  -> sets RC. OKFILE is the cleared-names file path.
run_hook() {
  local body="$1" okfile="$2" cmd payload
  cmd="gh issue create --repo fake-owner/fake-public --title t --body \"$body\""
  payload="$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$cmd")"
  RC=0
  printf '%s' "$payload" | env STUB="$STUB" \
    PRIVATE_DETAIL_REPO_VISIBILITY_SCRIPT="$TMP/rv_stub.sh" \
    PRIVATE_DETAIL_LOG_DIR="$TMP/logs" \
    PRIVATE_DETAIL_NO_REFRESH_KICK=1 \
    PRIVATE_NAMES_PUBLIC_OK_FILE="$okfile" \
    bash "$HOOK" >/dev/null 2>"$TMP/err" || RC=$?
}
verdict() { if [ "$RC" -eq 2 ]; then echo BLOCK; else echo ALLOW; fi; }

printf 'zzfakeproj\t%s/fake/zzfakeproj\tprivate\n' "$TMP" > "$STUB/cands.tsv"
printf 'zzotherproj\t%s/fake/zzotherproj\tprivate\n' "$TMP" >> "$STUB/cands.tsv"

OKF="$TMP/ok_main.txt"
printf '# owner-cleared\n\nzzfakeproj\n' > "$OKF"

echo "== cleared name is not a bare scan term =="
run_hook "see zzfakeproj for detail" "$OKF"
expect ALLOW "$(verdict)" "listed discovered name is allowed"

run_hook "see zzfakeproj for detail" "$TMP/ok_absent.txt"
expect BLOCK "$(verdict)" "falsification: file absent -> same text blocks"

run_hook "see zzotherproj for detail" "$OKF"
expect BLOCK "$(verdict)" "unlisted name still blocks"

printf 'ZZFakeProj\n' > "$TMP/ok_upper.txt"
run_hook "see zzfakeproj for detail" "$TMP/ok_upper.txt"
expect ALLOW "$(verdict)" "upper-case entry in the file matches (case-insensitive, stoplist convention)"

echo "== file format =="
printf '# zzotherproj is only a comment\n\n   \n' > "$TMP/ok_comments.txt"
run_hook "see zzotherproj for detail" "$TMP/ok_comments.txt"
expect BLOCK "$(verdict)" "comment and blank lines clear nothing"
printf 'zzotherproj\r\n' > "$TMP/ok_crlf.txt"
run_hook "see zzotherproj for detail" "$TMP/ok_crlf.txt"
expect ALLOW "$(verdict)" "CRLF line ending still matches"

echo "== what the file never exempts =="
run_hook "files live under $TMP/fake/zzfakeproj/notes" "$OKF"
expect BLOCK "$(verdict)" "absolute path of a cleared name still blocks"

printf 'zzfakeproj\t\tconfidential_by_policy\n' > "$STUB/cands.tsv"
run_hook "see zzfakeproj for detail" "$OKF"
expect BLOCK "$(verdict)" "DECLARED name is never cleared by this file"

printf '%s\t%s/fake/canary\tprivate\n' "$CANARY" "$TMP" > "$STUB/cands.tsv"
printf '%s\n' "$CANARY" > "$TMP/ok_canary.txt"
run_hook "see $CANARY here" "$TMP/ok_canary.txt"
expect BLOCK "$(verdict)" "canary entry can never be cleared"

echo "== unreadable file fails closed =="
printf 'zzfakeproj\t%s/fake/zzfakeproj\tprivate\n' "$TMP" > "$STUB/cands.tsv"
printf 'zzfakeproj\n' > "$TMP/ok_unreadable.txt"
chmod 000 "$TMP/ok_unreadable.txt"
if [ -r "$TMP/ok_unreadable.txt" ]; then
  echo "SKIP  running as a user that can read mode-000 files; unreadable case not testable"
else
  run_hook "see zzfakeproj for detail" "$TMP/ok_unreadable.txt"
  expect BLOCK "$(verdict)" "existing-but-unreadable file -> no exemption (blocks)"
  chmod 600 "$TMP/ok_unreadable.txt"
  run_hook "see zzfakeproj for detail" "$TMP/ok_unreadable.txt"
  expect ALLOW "$(verdict)" "falsification: same file made readable -> allowed"
fi

echo ""
echo "test_private_repo_detail_guard_public_ok: $PASS/$TOTAL PASS"
[ "$PASS" -eq "$TOTAL" ] && exit 0
exit 1
