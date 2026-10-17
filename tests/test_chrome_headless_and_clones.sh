#!/usr/bin/env bash
# test_chrome_headless_and_clones.sh -- llm#1414 and llm#1406
#
# Covers:
#   .claude/scripts/headless_chrome.sh  (chrome-headless-shell wrapper, llm#1414)
#   .claude/scripts/disk_headroom_check.sh --clones (Chrome code-sign clone
#   report, llm#1406)
#
# All fixtures live in a mktemp dir. The real /private/var/folders, the real
# Chrome and the real puppeteer cache are never touched: the wrapper gets a stub
# binary via HEADLESS_CHROME_SHELL and the disk check gets fixture roots via
# DISK_HEADROOM_CLONE_ROOTS. Bash 3.2 compatible.
#
# Exit: 0 all pass, 1 any failure.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WRAP="$ROOT/.claude/scripts/headless_chrome.sh"
DISK="$ROOT/.claude/scripts/disk_headroom_check.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/chrome_headless_test.XXXXXX")" || exit 3
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "PASS: $1"; }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }
check_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2' want '$3')"; fi; }
check_has() { if printf '%s' "$2" | grep -q -- "$3"; then ok "$1"; else bad "$1 (missing '$3' in: $2)"; fi; }
check_not() { if printf '%s' "$2" | grep -q -- "$3"; then bad "$1 (found '$3' in: $2)"; else ok "$1"; fi; }

# ---------------------------------------------------------------- wrapper
# Stub chrome-headless-shell. STUB_MODE: ok | fail7 | hang | stubborn.
STUB="$TMP/chrome-headless-shell"
cat > "$STUB" <<'EOF'
#!/bin/bash
echo "$@" > "$STUB_OUT/args"
for a in "$@"; do
  case "$a" in --user-data-dir=*) echo "${a#--user-data-dir=}" > "$STUB_OUT/profile" ;; esac
done
echo "$$" > "$STUB_OUT/pid"
profile="$(cat "$STUB_OUT/profile")"
: > "$profile/Cache"
case "${STUB_MODE:-ok}" in
  ok) exit 0 ;;
  fail7) exit 7 ;;
  hang) while :; do sleep 1; done ;;
  stubborn) trap '' TERM; while :; do sleep 1; done ;;
esac
EOF
chmod +x "$STUB"
OUT="$TMP/out"
mkdir -p "$OUT"
export STUB_OUT="$OUT"

# 1. missing binary -> exit 3, install hint, no fallback to the full app
EMPTYCACHE="$TMP/emptycache"
mkdir -p "$EMPTYCACHE"
msg="$(env -u HEADLESS_CHROME_SHELL HEADLESS_CHROME_CACHE="$EMPTYCACHE" bash "$WRAP" --dump-dom about:blank 2>&1)"
rc=$?
check_eq "missing shell binary -> exit 3" "$rc" 3
check_has "missing shell binary -> install hint" "$msg" 'puppeteer'
check_not "missing shell binary -> no silent fallback to full app" "$msg" 'Google Chrome.app/Contents/MacOS'

# 2. override pointing at the full app is refused (exit 3)
FULL="$TMP/Google Chrome.app/Contents/MacOS"
mkdir -p "$FULL"
cp "$STUB" "$FULL/Google Chrome"
msg="$(HEADLESS_CHROME_SHELL="$FULL/Google Chrome" bash "$WRAP" --dump-dom about:blank 2>&1)"
rc=$?
check_eq "full-app override refused -> exit 3" "$rc" 3
if [ -e "$OUT/args" ]; then bad "refused full app must not be executed"; else ok "refused full app was not executed"; fi

# 3. normal run: flags, own profile, profile removed, exit code propagated
rm -f "$OUT"/*
HEADLESS_CHROME_SHELL="$STUB" bash "$WRAP" --screenshot=/x.png https://example.invalid/ >/dev/null 2>&1
rc=$?
check_eq "normal run -> exit 0" "$rc" 0
args="$(cat "$OUT/args" 2>/dev/null)"
check_has "passes caller args" "$args" '--screenshot=/x.png https://example.invalid/'
check_has "uses a fresh --user-data-dir" "$args" '--user-data-dir='
profile="$(cat "$OUT/profile" 2>/dev/null)"
if [ -n "$profile" ] && [ ! -e "$profile" ]; then ok "profile dir removed after normal run"; else bad "profile dir left behind: '$profile'"; fi

rm -f "$OUT"/*
STUB_MODE=fail7 HEADLESS_CHROME_SHELL="$STUB" bash "$WRAP" about:blank >/dev/null 2>&1
rc=$?
check_eq "child exit code propagated" "$rc" 7
profile="$(cat "$OUT/profile" 2>/dev/null)"
if [ -n "$profile" ] && [ ! -e "$profile" ]; then ok "profile dir removed after failing run"; else bad "profile dir left behind after failure: '$profile'"; fi

# 4. hang -> TERM, exit 124, profile removed, child gone
rm -f "$OUT"/*
STUB_MODE=hang HEADLESS_CHROME_SHELL="$STUB" bash "$WRAP" --timeout 1 about:blank >/dev/null 2>&1
rc=$?
check_eq "hung child -> exit 124" "$rc" 124
profile="$(cat "$OUT/profile" 2>/dev/null)"
pid="$(cat "$OUT/pid" 2>/dev/null)"
if [ -n "$profile" ] && [ ! -e "$profile" ]; then ok "profile dir removed after timeout"; else bad "profile dir left after timeout: '$profile'"; fi
if kill -0 "$pid" 2>/dev/null; then bad "hung child still alive after timeout"; else ok "hung child terminated"; fi

# 5. child ignoring TERM is KILLed after the grace period
rm -f "$OUT"/*
STUB_MODE=stubborn HEADLESS_CHROME_GRACE=1 HEADLESS_CHROME_SHELL="$STUB" bash "$WRAP" --timeout 1 about:blank >/dev/null 2>&1
rc=$?
check_eq "TERM-ignoring child -> exit 124" "$rc" 124
pid="$(cat "$OUT/pid" 2>/dev/null)"
if kill -0 "$pid" 2>/dev/null; then bad "TERM-ignoring child survived (no KILL)"; else ok "TERM-ignoring child KILLed"; fi

# 6. wrapper itself killed mid-run: profile removed, child terminated
rm -f "$OUT"/*
STUB_MODE=hang HEADLESS_CHROME_SHELL="$STUB" bash "$WRAP" --timeout 60 about:blank >/dev/null 2>&1 &
wpid=$!
i=0
while [ ! -s "$OUT/pid" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
kill -TERM "$wpid" 2>/dev/null
wait "$wpid" 2>/dev/null
sleep 0.5
profile="$(cat "$OUT/profile" 2>/dev/null)"
pid="$(cat "$OUT/pid" 2>/dev/null)"
if [ -n "$profile" ] && [ ! -e "$profile" ]; then ok "wrapper killed -> profile dir removed"; else bad "wrapper killed -> profile left: '$profile'"; fi
if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then ok "wrapper killed -> child terminated"; else bad "wrapper killed -> child alive (pid '$pid')"; fi

# ------------------------------------------------------------- clone report
CR="$TMP/croot"
APP="$TMP/app/Google Chrome.app"
FW="Contents/Frameworks/Google Chrome Framework.framework/Versions"
mkdir -p "$APP/$FW/154.0.8037.99"
ln -s 154.0.8037.99 "$APP/$FW/Current"
mk_clone() { # mk_clone <root> <id> <version>
    mkdir -p "$1/com.google.Chrome.code_sign_clone/code_sign_clone.$2/Google Chrome.app/$FW/$3"
}
mk_clone "$CR" a1 154.0.8037.99
mk_clone "$CR" a2 154.0.8037.93
mk_clone "$CR" a3 154.0.8037.93
mk_clone "$CR" a4 152.0.7977.75
mkdir -p "$CR/nix-shell-big" "$CR/Rtmp1234" "$CR/unrelated"
dd if=/dev/zero of="$CR/nix-shell-big/blob" bs=1024 count=300 2>/dev/null
dd if=/dev/zero of="$CR/Rtmp1234/blob" bs=1024 count=50 2>/dev/null
dd if=/dev/zero of="$CR/unrelated/blob" bs=1024 count=900 2>/dev/null

before="$(find "$CR" | sort | md5 2>/dev/null || find "$CR" | sort | md5sum)"
out="$(DISK_HEADROOM_CLONE_ROOTS="$CR" DISK_HEADROOM_CHROME_APP="$APP" bash "$DISK" --clones 2>&1)"
rc=$?
check_eq "--clones exits 0 on measurable roots" "$rc" 0
check_has "--clones reports clone count" "$out" 'clones: 4'
check_has "--clones reports distinct versions" "$out" '3 versions'
check_has "--clones counts per version" "$out" '2 154.0.8037.93'
check_has "--clones marks the installed version" "$out" '154.0.8037.99.*installed'
check_has "--clones marks not-installed versions stale" "$out" '152.0.7977.75.*stale'
check_has "--clones says du over-counts" "$out" 'du over-counts'
check_has "--clones lists nix-shell temp dir" "$out" 'nix-shell-big'
check_has "--clones lists Rtmp temp dir" "$out" 'Rtmp1234'
check_not "--clones ignores unrelated temp dirs" "$out" 'unrelated'
after="$(find "$CR" | sort | md5 2>/dev/null || find "$CR" | sort | md5sum)"
check_eq "--clones deletes nothing" "$after" "$before"

out="$(DISK_HEADROOM_CLONE_ROOTS="$TMP/does-not-exist" bash "$DISK" --clones 2>&1)"
rc=$?
check_eq "unmeasurable roots -> exit 3" "$rc" 3
check_has "unmeasurable roots -> INDETERMINATE, not clean" "$out" 'INDETERMINATE'
check_not "unmeasurable roots never says 0 clones" "$out" 'clones: 0'

EMPTYR="$TMP/emptyroot"
mkdir -p "$EMPTYR"
out="$(DISK_HEADROOM_CLONE_ROOTS="$EMPTYR" bash "$DISK" --clones 2>&1)"
rc=$?
check_eq "measurable root without clones -> exit 0" "$rc" 0
check_has "measurable root without clones -> clones: 0" "$out" 'clones: 0'

echo "RESULTS: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
