#!/usr/bin/env bash
# headless_chrome.sh -- run chrome-headless-shell safely (llm#1414)
#
# Why: launching the full "Google Chrome.app" headlessly makes an APFS clone of
# the whole ~2 GB app bundle under the per-user temp folder
# (com.google.Chrome.code_sign_clone). Chrome removes it only on a clean exit,
# so a launch killed by a Bash timeout leaks ~2 GB. chrome-headless-shell makes
# no such clone (measured in llm#1414).
#
# This wrapper runs chrome-headless-shell with a fresh --user-data-dir that is
# removed by a trap, and a watchdog that sends TERM and then KILL.
#
# Usage:
#   headless_chrome.sh [--timeout SECS] [--] <chrome flags and URL...>
#   e.g. headless_chrome.sh --screenshot=/tmp/p.png --window-size=1280,800 URL
#
# Flags added for you: --headless --disable-gpu --user-data-dir=<fresh temp>.
#
# Environment:
#   HEADLESS_CHROME_SHELL  explicit chrome-headless-shell binary (a path inside
#                          a "Google Chrome.app" bundle is refused)
#   HEADLESS_CHROME_CACHE  where to look (default ~/.cache/puppeteer/chrome-headless-shell)
#   HEADLESS_CHROME_TIMEOUT default timeout in seconds (default 60)
#   HEADLESS_CHROME_GRACE  seconds between TERM and KILL (default 5)
#
# Exit codes: the browser's own code on a normal run; 124 timed out; 2 usage;
# 3 INDETERMINATE (no chrome-headless-shell found). It never falls back to the
# full Chrome app. Install the shell with:
#   npx --yes @puppeteer/browsers install chrome-headless-shell@stable --path ~/.cache/puppeteer
# (puppeteer's own install also works: it fills ~/.cache/puppeteer/chrome-headless-shell).

set -uo pipefail

TIMEOUT="${HEADLESS_CHROME_TIMEOUT:-60}"
GRACE="${HEADLESS_CHROME_GRACE:-5}"
CACHE="${HEADLESS_CHROME_CACHE:-$HOME/.cache/puppeteer/chrome-headless-shell}"

while [ $# -gt 0 ]; do
    case "$1" in
        --timeout)
            [ $# -ge 2 ] || { echo "headless_chrome: --timeout needs a value" >&2; exit 2; }
            TIMEOUT="$2"; shift 2 ;;
        --) shift; break ;;
        *) break ;;
    esac
done
case "$TIMEOUT" in ''|*[!0-9]*) echo "headless_chrome: bad timeout '$TIMEOUT'" >&2; exit 2 ;; esac
case "$GRACE" in ''|*[!0-9]*) echo "headless_chrome: bad grace '$GRACE'" >&2; exit 2 ;; esac
if [ $# -eq 0 ]; then
    echo "usage: headless_chrome.sh [--timeout SECS] [--] <chrome flags and URL...>" >&2
    exit 2
fi

BIN="${HEADLESS_CHROME_SHELL:-}"
if [ -z "$BIN" ] && [ -d "$CACHE" ]; then
    BIN="$(find "$CACHE" -type f -name chrome-headless-shell 2>/dev/null | sort | tail -n 1)"
fi
case "$BIN" in
    *"Google Chrome.app"*)
        echo "headless_chrome: INDETERMINATE: refusing the full Chrome app ($BIN); it leaks a ~2 GB code-sign clone per killed launch (llm#1414)" >&2
        exit 3 ;;
esac
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
    echo "headless_chrome: INDETERMINATE: chrome-headless-shell not found (looked in $CACHE). Not falling back to the full Chrome app." >&2
    echo "headless_chrome: install it with: npx --yes @puppeteer/browsers install chrome-headless-shell@stable --path \$HOME/.cache/puppeteer" >&2
    exit 3
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/headless_chrome.XXXXXX")" || { echo "headless_chrome: INDETERMINATE: cannot create temp dir" >&2; exit 3; }
PROFILE="$WORK/profile"
mkdir -p "$PROFILE"
CHILD=""
WATCHDOG=""

cleanup() {
    if [ -n "$WATCHDOG" ]; then
        pkill -P "$WATCHDOG" 2>/dev/null
        kill "$WATCHDOG" 2>/dev/null
    fi
    if [ -n "$CHILD" ] && kill -0 "$CHILD" 2>/dev/null; then
        kill -TERM "$CHILD" 2>/dev/null
        sleep 0.2
        kill -0 "$CHILD" 2>/dev/null && kill -KILL "$CHILD" 2>/dev/null
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT HUP

"$BIN" --headless --disable-gpu "--user-data-dir=$PROFILE" "$@" &
CHILD=$!

(
    sleep "$TIMEOUT"
    : > "$WORK/timedout"
    kill -TERM "$CHILD" 2>/dev/null
    sleep "$GRACE"
    kill -KILL "$CHILD" 2>/dev/null
) &
WATCHDOG=$!

wait "$CHILD"
rc=$?
if [ -e "$WORK/timedout" ]; then
    echo "headless_chrome: timed out after ${TIMEOUT}s" >&2
    exit 124
fi
exit "$rc"
