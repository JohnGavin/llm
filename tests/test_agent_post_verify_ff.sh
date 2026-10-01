#!/usr/bin/env bash
# Tests for agent-post-verify.sh: a fast-forward to origin is not agent drift.
# Throwaway repos in mktemp dirs only; HOME is redirected so the log is not touched.
set -u

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${POST_VERIFY_SCRIPT:-$HERE/.claude/scripts/agent-post-verify.sh}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

commit() { # repo msg
    echo "$2" >> "$1/f.txt"
    git -C "$1" add f.txt
    git -C "$1" commit -q -m "$2"
}

# new_world <name>: bare origin + "main" clone (the checked repo) + "other" clone (pusher)
new_world() {
    W="$TMP/$1"
    mkdir -p "$W"
    git init -q --bare -b main "$W/origin.git"
    git clone -q "$W/origin.git" "$W/repo" 2>/dev/null
    git -C "$W/repo" checkout -q -b main 2>/dev/null
    commit "$W/repo" base
    git -C "$W/repo" push -q -u origin main
    git clone -q "$W/origin.git" "$W/other" 2>/dev/null
}

run_check() { # world id -> sets OUT, RC
    OUT="$(bash "$SCRIPT" check "$W/repo" --id "$1" 2>&1)"
    RC=$?
}

# (a) fast-forward to origin/main -> benign
new_world a
bash "$SCRIPT" capture "$W/repo" --id a >/dev/null
commit "$W/other" remote-one
commit "$W/other" remote-two
git -C "$W/other" push -q origin main
git -C "$W/repo" pull -q --ff-only origin main
run_check a
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q FAST_FORWARD_TO_REMOTE \
   && echo "$OUT" | grep -q remote-one && ! echo "$OUT" | grep -q 'reset --hard'; then
    pass "(a) ff to origin -> FAST_FORWARD_TO_REMOTE exit 0"
else
    fail "(a) expected FAST_FORWARD_TO_REMOTE exit 0, got rc=$RC: $OUT"
fi

# (b) local unpushed commit -> drift, lists only that commit
new_world b
bash "$SCRIPT" capture "$W/repo" --id b >/dev/null
commit "$W/repo" local-only-b
run_check b
if [ "$RC" -eq 1 ] && echo "$OUT" | grep -q HEAD_MOVED_SAME_BRANCH \
   && echo "$OUT" | grep -q local-only-b && ! echo "$OUT" | grep -q FAST_FORWARD_TO_REMOTE; then
    pass "(b) local commit -> HEAD_MOVED_SAME_BRANCH exit 1"
else
    fail "(b) expected drift exit 1, got rc=$RC: $OUT"
fi
if echo "$OUT" | grep -q 'Do NOT run' && ! echo "$OUT" | grep -qE '^ +git .*reset --hard'; then
    pass "(b) recovery text does not instruct reset --hard"
else
    fail "(b) recovery text still instructs reset --hard: $OUT"
fi

# (c) ff to origin plus one local commit -> drift, lists only the local one
new_world c
bash "$SCRIPT" capture "$W/repo" --id c >/dev/null
commit "$W/other" remote-c
git -C "$W/other" push -q origin main
git -C "$W/repo" pull -q --ff-only origin main
commit "$W/repo" local-only-c
run_check c
if [ "$RC" -eq 1 ] && echo "$OUT" | grep -q HEAD_MOVED_SAME_BRANCH \
   && echo "$OUT" | grep -q local-only-c && ! echo "$OUT" | grep -q 'remote-c'; then
    pass "(c) ff + local commit -> drift listing only the local commit"
else
    fail "(c) expected drift listing only local-only-c, got rc=$RC: $OUT"
fi

# (d) no remote -> INDETERMINATE exit 3
D="$TMP/d"
git init -q -b main "$D"
commit "$D" base
bash "$SCRIPT" capture "$D" --id d >/dev/null
commit "$D" moved
OUT="$(bash "$SCRIPT" check "$D" --id d 2>&1)"
RC=$?
if [ "$RC" -eq 3 ] && echo "$OUT" | grep -q INDETERMINATE; then
    pass "(d) no remote -> INDETERMINATE exit 3"
else
    fail "(d) expected INDETERMINATE exit 3, got rc=$RC: $OUT"
fi

# (e) no move at all still OK (unchanged verdict)
new_world e
bash "$SCRIPT" capture "$W/repo" --id e >/dev/null
run_check e
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q '^OK: no drift'; then
    pass "(e) no change -> OK exit 0"
else
    fail "(e) expected OK exit 0, got rc=$RC: $OUT"
fi

rm -f /tmp/agent-post-verify-*-[abcde].txt 2>/dev/null
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$fails FAILED"
exit 1
