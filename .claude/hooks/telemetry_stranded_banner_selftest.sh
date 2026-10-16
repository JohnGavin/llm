#!/usr/bin/env bash
# telemetry_stranded_banner_selftest.sh
# Selftest for .claude/scripts/telemetry_stranded_banner.sh (session_init Phase 15i).
# Uses temp log fixtures only (TELEMETRY_STRANDED_LOG); never touches
# ~/.claude/logs/telemetry_stranded_runs.log.
#
# Cases: recent -> line; only-old -> silent; empty/missing -> silent;
# garbage timestamps -> INDETERMINATE; unreadable -> INDETERMINATE;
# mixed good+garbage -> line with note. Case 7 falsifies the "only-old ->
# silent" assertion against a deliberately broken copy of the reader.
#
# Usage: bash telemetry_stranded_banner_selftest.sh   Exit: 0 PASS, 1 FAIL

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/../scripts/telemetry_stranded_banner.sh"
TMP=$(mktemp -d)
trap 'chmod -R u+rw "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
FAILS=0
ok()   { echo "PASS: $1"; }
bad()  { echo "FAIL: $1" >&2; FAILS=$((FAILS + 1)); }

dago() { date -v-"$1"d '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date -d "$1 days ago" '+%Y-%m-%dT%H:%M:%S%z'; }
run()  { TELEMETRY_STRANDED_LOG="$1" bash "${2:-$SCRIPT}"; }

RECENT=$(dago 0)
OLD=$(dago 10)

# 1 recent entries -> one line with count, date, last kind
L1="$TMP/l1.log"
{
  printf '%s repo=/x conflicts=1 files=[a.json ]\n' "$OLD"
  printf '%s kind=codexbar_refresh_abort exit=1 reason=[boom]\n' "$RECENT"
  printf '%s repo=/x conflicts=1 files=[a.json ] kind=export_optional_step_error\n' "$RECENT"
} > "$L1"
out=$(run "$L1")
want="telemetry-stranded: 2 in last 3d (last: ${RECENT%%T*} export_optional_step_error) -- see ${L1}"
[ "$out" = "$want" ] && ok "1 recent entries -> compact line" || bad "1 got: [$out] want: [$want]"

# 1b older line without kind= is reported as stranded_run
L1B="$TMP/l1b.log"
printf '%s repo=/x conflicts=2 files=[a b ]\n' "$RECENT" > "$L1B"
out=$(run "$L1B")
case "$out" in *"1 in last 3d"*"stranded_run)"*) ok "1b kindless legacy line -> stranded_run" ;; *) bad "1b got: [$out]" ;; esac

# 2 only old entries -> silent
L2="$TMP/l2.log"
printf '%s repo=/x conflicts=1 files=[a ]\n' "$OLD" > "$L2"
out=$(run "$L2")
[ -z "$out" ] && ok "2 only-old entries -> silent" || bad "2 got: [$out]"

# 3 empty and missing -> silent
: > "$TMP/l3.log"
out=$(run "$TMP/l3.log")
[ -z "$out" ] && ok "3a empty file -> silent" || bad "3a got: [$out]"
out=$(run "$TMP/does-not-exist.log")
[ -z "$out" ] && ok "3b missing file -> silent" || bad "3b got: [$out]"

# 4 garbage timestamps only -> INDETERMINATE
L4="$TMP/l4.log"
printf 'not-a-timestamp something broke\n9999 whatever\n' > "$L4"
out=$(run "$L4")
case "$out" in "telemetry-stranded: INDETERMINATE"*) ok "4 garbage timestamps -> INDETERMINATE" ;; *) bad "4 got: [$out]" ;; esac

# 5 unreadable file -> INDETERMINATE (skipped when running as root)
L5="$TMP/l5.log"
printf '%s kind=x\n' "$RECENT" > "$L5"
chmod 000 "$L5"
if [ -r "$L5" ]; then
  echo "SKIP: 5 unreadable (file still readable, running as root?)"
else
  out=$(run "$L5")
  case "$out" in "telemetry-stranded: INDETERMINATE (cannot read"*) ok "5 unreadable -> INDETERMINATE" ;; *) bad "5 got: [$out]" ;; esac
fi

# 6 recent + garbage -> positive answer still printed, with note
L6="$TMP/l6.log"
{ printf 'garbage line\n'; printf '%s kind=codexbar_refresh_abort exit=1 reason=[x]\n' "$RECENT"; } > "$L6"
out=$(run "$L6")
case "$out" in *"1 in last 3d"*"(+1 unparseable lines)"*) ok "6 recent+garbage -> line with note" ;; *) bad "6 got: [$out]" ;; esac

# 7 FALSIFICATION: a broken reader (cutoff check disabled) must make case 2 go red
BROKEN="$TMP/broken_banner.sh"
sed 's/day >= cutoff/day >= "0000"/' "$SCRIPT" > "$BROKEN"
if cmp -s "$SCRIPT" "$BROKEN"; then
  bad "7 falsification: sed did not alter the reader (pattern drifted)"
else
  out=$(run "$L2" "$BROKEN")
  if [ -n "$out" ]; then
    ok "7 falsified: broken reader prints for old-only log (case 2 assertion goes red): $out"
  else
    bad "7 falsification: broken reader stayed silent; case 2 cannot fail"
  fi
fi

# 8 opt-out and N override
out=$(CLAUDE_TELEMETRY_STRANDED_CHECK=0 run "$L1")
[ -z "$out" ] && ok "8a opt-out -> silent" || bad "8a got: [$out]"
out=$(TELEMETRY_STRANDED_DAYS=30 run "$L2")
case "$out" in *"1 in last 30d"*) ok "8b N override widens window" ;; *) bad "8b got: [$out]" ;; esac

# 9 exit status is always 0
TELEMETRY_STRANDED_LOG="$L4" bash "$SCRIPT" >/dev/null; rc=$?
[ "$rc" -eq 0 ] && ok "9 exits 0 even when INDETERMINATE" || bad "9 rc=$rc"

echo ""
if [ "$FAILS" -eq 0 ]; then echo "SELFTEST: PASS"; exit 0; else echo "SELFTEST: $FAILS FAIL" >&2; exit 1; fi
