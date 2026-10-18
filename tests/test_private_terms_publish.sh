#!/usr/bin/env bash
# Test for .claude/scripts/private_terms_publish.sh (llm#1389). Synthetic term
# lists in a temp dir and a stub gh (PRIVATE_TERMS_PUBLISH_GH). The real gh,
# the real ~/.config/private_terms.txt and the real state/log files are never
# touched. All terms below are synthetic.
#
# Falsification is built in: a verify-step mutant and a state-write mutant of
# the script are run against the matching tests and MUST go red.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REAL_SCRIPT="$ROOT/.claude/scripts/private_terms_publish.sh"
WORK=$(mktemp -d)
WORK=$(cd -P "$WORK" && pwd -P)
trap 'rm -rf "$WORK"' EXIT

CANARY="zzcanary""privterm7q"
mkdir -p "$WORK/home"
export HOME="$WORK/home"
export TMPDIR="$WORK/tmp"
mkdir -p "$TMPDIR"

cat > "$WORK/gh_stub" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DIR/argv.log"
case "$1 $2" in
  "secret set")
    name="$3"
    cat > "$STUB_DIR/$name.stdin"
    echo set >> "$STUB_DIR/sets.log"
    if [ "${STUB_SET_FAIL:-0}" = "1" ]; then echo "stub failure" >&2; exit 1; fi
    if [ "${STUB_NOMOVE:-0}" != "1" ]; then
      n=$(cat "$STUB_DIR/$name.ts" 2>/dev/null || echo 0)
      echo $((n + 1)) > "$STUB_DIR/$name.ts"
    fi
    ;;
  "secret list")
    h=$(cat "$STUB_DIR/PRIVATE_TERM_HASHES.ts" 2>/dev/null || echo 0)
    s=$(cat "$STUB_DIR/PRIVATE_TERMS_SALT.ts" 2>/dev/null || echo 0)
    printf '[{"name":"PRIVATE_TERM_HASHES","updatedAt":"2026-10-18T00:00:%02dZ"},{"name":"PRIVATE_TERMS_SALT","updatedAt":"2026-10-18T00:00:%02dZ"}]\n' "$h" "$s"
    ;;
esac
exit 0
EOF
chmod +x "$WORK/gh_stub"

fail=0
check() { # label expected actual
  if [ "$2" = "$3" ]; then echo "PASS $1 ($3)"; else echo "FAIL $1: expected '$2' got '$3'"; fail=1; fi
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
old_iso() {
  date -u -v-30d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '30 days ago' +%Y-%m-%dT%H:%M:%SZ
}
# mklist HEADER_TS [terms...]  (canary always added unless NOCANARY=1)
mklist() {
  local ts="$1"; shift
  {
    printf '# private_terms v1 generated=%s count=%s\n' "$ts" "$#"
    local t
    for t in "$@"; do printf '%s\n' "$t"; done
    if [ "${NOCANARY:-0}" != "1" ]; then printf '%s\n' "$CANARY"; fi
  } > "$PRIVATE_TERMS_FILE"
}

SANDBOX=""
fresh() {
  SANDBOX="$WORK/case.$1"
  rm -rf "$SANDBOX"; mkdir -p "$SANDBOX/stub"
  rm -rf "$TMPDIR"; mkdir -p "$TMPDIR"
  export STUB_DIR="$SANDBOX/stub"
  export PRIVATE_TERMS_FILE="$SANDBOX/terms.txt"
  export PRIVATE_TERMS_PUBLISH_GH="$WORK/gh_stub"
  export PRIVATE_TERMS_PUBLISH_STATE="$SANDBOX/state.sha"
  export PRIVATE_TERMS_PUBLISH_LOG="$SANDBOX/publish.log"
  unset STUB_SET_FAIL STUB_NOMOVE NOCANARY
}
RC=0
run() { # script args...
  local s="$1"; shift
  bash "$s" "$@" > "$SANDBOX/out" 2> "$SANDBOX/err"
  RC=$?
}
nsets() { if [ -f "$STUB_DIR/sets.log" ]; then wc -l < "$STUB_DIR/sets.log" | tr -d ' '; else echo 0; fi; }
state_present() { if [ -f "$PRIVATE_TERMS_PUBLISH_STATE" ]; then echo yes; else echo no; fi; }
tmp_left() { ls -A "$TMPDIR" | wc -l | tr -d ' '; }

# Runs every scenario against script $1; prefix $2 labels the output.
scenarios() {
  local S="$1" P="$2"

  fresh "$P.dry"; mklist "$(now_iso)" alphaonezz "beta twozz"
  run "$S"
  check "$P dry-run exit" 0 "$RC"
  check "$P dry-run sets nothing" 0 "$(nsets)"
  check "$P dry-run writes no state" no "$(state_present)"
  check "$P dry-run leaves no temp" 0 "$(tmp_left)"

  fresh "$P.apply"; mklist "$(now_iso)" alphaonezz "beta twozz"
  run "$S" --apply
  check "$P apply exit" 0 "$RC"
  check "$P apply sets both secrets" 2 "$(nsets)"
  check "$P apply writes state" yes "$(state_present)"
  check "$P apply leaves no temp" 0 "$(tmp_left)"
  local order
  order="$(grep '^secret set' "$STUB_DIR/argv.log" | awk '{print $3}' | tr '\n' ' ')"
  check "$P apply order" "PRIVATE_TERM_HASHES PRIVATE_TERMS_SALT " "$order"
  local salt
  salt="$(cat "$STUB_DIR/PRIVATE_TERMS_SALT.stdin" 2>/dev/null)"
  local hline
  hline="$(sed -n '2p' "$STUB_DIR/PRIVATE_TERM_HASHES.stdin" 2>/dev/null)"
  check "$P salt arrived on stdin (32 hex)" 32 "${#salt}"
  check "$P hash payload header" "maxtokens=2" "$(head -n 1 "$STUB_DIR/PRIVATE_TERM_HASHES.stdin")"
  local leaks=0 v f
  for v in "$salt" "$hline" alphaonezz "beta twozz"; do
    for f in "$STUB_DIR/argv.log" "$SANDBOX/out" "$SANDBOX/err" "$PRIVATE_TERMS_PUBLISH_LOG" "$PRIVATE_TERMS_PUBLISH_STATE"; do
      if [ -n "$v" ] && grep -q -F -- "$v" "$f" 2>/dev/null; then leaks=$((leaks + 1)); fi
    done
  done
  check "$P no secret/term in argv, stdout, stderr, log, state" 0 "$leaks"
  check "$P log has DESTRUCTIVE lines" 2 "$(grep -c '^DESTRUCTIVE:' "$PRIVATE_TERMS_PUBLISH_LOG")"

  # unchanged -> current
  rm -f "$STUB_DIR/sets.log"
  run "$S" --apply
  check "$P unchanged exit" 0 "$RC"
  check "$P unchanged says current" yes "$(grep -q '^current' "$SANDBOX/out" && echo yes || echo no)"
  check "$P unchanged no gh set" 0 "$(nsets)"

  # header-only change -> still current
  sleep 1
  mklist "$(now_iso)" alphaonezz "beta twozz"
  sed -i.bak '1s/count=[0-9]*/count=99/' "$PRIVATE_TERMS_FILE"; rm -f "$PRIVATE_TERMS_FILE.bak"
  run "$S" --apply
  check "$P header-only change still current" yes "$(grep -q '^current' "$SANDBOX/out" && echo yes || echo no)"
  check "$P header-only change no gh set" 0 "$(nsets)"

  # changed list -> republish
  mklist "$(now_iso)" alphaonezz "beta twozz" gammathreezz
  run "$S" --apply
  check "$P changed list republishes" 2 "$(nsets)"

  fresh "$P.setfail"; mklist "$(now_iso)" alphaonezz
  export STUB_SET_FAIL=1
  run "$S" --apply
  check "$P set failure exit" 3 "$RC"
  check "$P set failure state NOT written" no "$(state_present)"
  check "$P set failure leaves no temp" 0 "$(tmp_left)"

  fresh "$P.nomove"; mklist "$(now_iso)" alphaonezz
  export STUB_NOMOVE=1
  run "$S" --apply
  check "$P verify failure exit" 3 "$RC"
  check "$P verify failure state NOT written" no "$(state_present)"
  check "$P verify failure leaves no temp" 0 "$(tmp_left)"

  fresh "$P.stale"; mklist "$(old_iso)" alphaonezz
  run "$S" --apply
  check "$P stale list exit" 3 "$RC"
  check "$P stale list sets nothing" 0 "$(nsets)"

  fresh "$P.nocanary"; NOCANARY=1 mklist "$(now_iso)" alphaonezz
  run "$S" --apply
  check "$P missing canary exit" 3 "$RC"
  check "$P missing canary sets nothing" 0 "$(nsets)"

  fresh "$P.nogh"; mklist "$(now_iso)" alphaonezz
  PRIVATE_TERMS_PUBLISH_GH="$WORK/does_not_exist" run "$S" --apply
  check "$P gh missing exit" 3 "$RC"
  check "$P gh missing state NOT written" no "$(state_present)"

  fresh "$P.usage"; mklist "$(now_iso)" alphaonezz
  run "$S" --bogus
  check "$P usage exit" 2 "$RC"
}

scenarios "$REAL_SCRIPT" real

# --- Heartbeat rows (housekeeping_runs) read by the overnight email.
if command -v duckdb >/dev/null 2>&1; then
  HKDB="$WORK/hk.duckdb"
  duckdb -init /dev/null "$HKDB" < "$ROOT/.claude/scripts/housekeeping_schema_init.sql" >/dev/null 2>&1
  hkq() { duckdb -init /dev/null -csv -noheader "$HKDB" -c "$1" 2>&1; }
  export UNIFIED_DB_PATH="$HKDB"

  fresh hk.dry; mklist "$(now_iso)" alphaonezz "beta twozz"
  run "$REAL_SCRIPT"
  check "hk dry-run writes no heartbeat" 0 "$(hkq "SELECT count(*) FROM housekeeping_runs WHERE task='private_terms_publish'")"

  fresh hk.apply; mklist "$(now_iso)" alphaonezz "beta twozz"
  run "$REAL_SCRIPT" --apply
  check "hk refresh: status ok" ok "$(hkq "SELECT status FROM housekeeping_runs WHERE task='private_terms_publish' ORDER BY started_at DESC, id LIMIT 1")"
  check "hk refresh: rows_written = term count (2 + canary)" 3 "$(hkq "SELECT rows_written FROM housekeeping_runs WHERE task='private_terms_publish' AND status='ok'")"

  run "$REAL_SCRIPT" --apply
  check "hk unchanged: status skipped" 1 "$(hkq "SELECT count(*) FROM housekeeping_runs WHERE task='private_terms_publish' AND status='skipped'")"

  fresh hk.fail; mklist "$(now_iso)" alphaonezz
  export STUB_SET_FAIL=1
  run "$REAL_SCRIPT" --apply
  check "hk failure: exit 3" 3 "$RC"
  check "hk failure: status failed" 1 "$(hkq "SELECT count(*) FROM housekeeping_runs WHERE task='private_terms_publish' AND status='failed'")"
  unset STUB_SET_FAIL UNIFIED_DB_PATH
else
  echo "SKIP: duckdb not on PATH -- heartbeat rows NOT exercised"
fi

# --- Falsification: mutants live in a copied tree so relative sourcing works.
MUT="$WORK/mut"
mkdir -p "$MUT/.claude/scripts/lib" "$MUT/.claude/hooks/lib"
cp "$ROOT/.claude/scripts/private_terms_hashes.sh" "$MUT/.claude/scripts/"
cp "$ROOT/.claude/scripts/lib/private_term_hash_lib.sh" "$MUT/.claude/scripts/lib/"
cp "$ROOT/.claude/hooks/lib/private_terms.sh" "$MUT/.claude/hooks/lib/"

# Mutant 1: verify step disabled (never notices a secret that did not move).
perl -pe 's/\[ "\$A_HASH" = "\$B_HASH" \]/false/; s/\[ "\$A_SALT" = "\$B_SALT" \]/false/' \
  "$REAL_SCRIPT" > "$MUT/.claude/scripts/private_terms_publish.sh"
if cmp -s "$REAL_SCRIPT" "$MUT/.claude/scripts/private_terms_publish.sh"; then
  echo "FAIL mutant 1 did not change the script (falsification vacuous)"; fail=1
fi
fresh mut1; mklist "$(now_iso)" alphaonezz
export STUB_NOMOVE=1
run "$MUT/.claude/scripts/private_terms_publish.sh" --apply
if [ "$RC" = "3" ] && [ "$(state_present)" = no ]; then
  echo "FAIL mutant 1 (verify disabled) was NOT caught by the verify-failure test"; fail=1
else
  echo "PASS mutant 1 (verify disabled) is caught: exit $RC, state $(state_present)"
fi

# Mutant 2: state written before the secrets are set (no-write-on-failure broken).
perl -pe 's/^if \[ "\$APPLY" -ne 1 \]; then/if [ "\$APPLY" -eq 1 ]; then mkdir -p "\$(dirname "\$STATE")"; printf "%s\\n" "\$FP" > "\$STATE"; fi\n$&/' \
  "$REAL_SCRIPT" > "$MUT/.claude/scripts/private_terms_publish.sh"
if cmp -s "$REAL_SCRIPT" "$MUT/.claude/scripts/private_terms_publish.sh"; then
  echo "FAIL mutant 2 did not change the script (falsification vacuous)"; fail=1
fi
fresh mut2; mklist "$(now_iso)" alphaonezz
export STUB_SET_FAIL=1
run "$MUT/.claude/scripts/private_terms_publish.sh" --apply
if [ "$(state_present)" = no ]; then
  echo "FAIL mutant 2 (early state write) was NOT caught by the set-failure test"; fail=1
else
  echo "PASS mutant 2 (early state write) is caught: state present after failed set"
fi

if [ "$fail" = 0 ]; then echo "ALL PASS"; exit 0; fi
echo "FAILURES"; exit 1
