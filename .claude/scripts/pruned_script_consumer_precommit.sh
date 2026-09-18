#!/usr/bin/env bash
# pruned_script_consumer_precommit.sh — pre-commit gate wrapper for
# pruned_script_consumer_check.sh (llm#1067).
#
# Maps the checker's three-way exit code onto commit behaviour:
#   0 (pass)          — silent, exit 0
#   1 (real consumer) — print findings, BLOCK the commit
#   3 (indeterminate) — print a loud warning, do NOT block (the checker
#                        could not search — that is a reason to look harder,
#                        not a reason to trust it, but nor is it grounds to
#                        halt every commit on this machine whenever
#                        ~/docs_gh is briefly unmounted or unreadable)
#   anything else      — same as indeterminate: warn, do not block
#
# Only fires when pruned_script_consumer_check.sh itself is present and
# executable, and only actually does work when the checker finds a guarded
# deletion staged (see that script's own header) — costs nothing on the
# overwhelming majority of commits.
#
# Kill switch: SKIP_CONSUMER_CHECK=1 — logged, never silent.
#
# Exit: 0 allow · 1 block
#
# llm#1067

set -uo pipefail

LOG="${HOME}/.claude/logs/pruned_script_consumer_precommit.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG" 2>/dev/null || true; }

if [ -n "${SKIP_CONSUMER_CHECK:-}" ]; then
    echo "pruned-script-consumer-check: SKIPPED (SKIP_CONSUMER_CHECK=1)"
    log "skipped via kill switch"
    exit 0
fi

CHECKER="${CONSUMER_CHECKER:-$HOME/.claude/scripts/pruned_script_consumer_check.sh}"
if [ ! -x "$CHECKER" ]; then
    echo "pruned-script-consumer-check: UNAVAILABLE (checker not executable at $CHECKER) — not blocking" >&2
    log "unavailable checker=$CHECKER"
    exit 0
fi

out="$("$CHECKER" 2>&1)"; rc=$?

case "$rc" in
    (0)
        log "pass"
        exit 0 ;;
    (1)
        echo "$out" >&2
        echo "" >&2
        echo "Commit BLOCKED: a deleted script/hook/template still has a surviving" >&2
        echo "consumer under \$HOME/docs_gh (see llm#1067 — #773 deleted a script a" >&2
        echo "downstream project still called by absolute path; the breakage ran" >&2
        echo "silently for six weeks)." >&2
        echo "" >&2
        echo "  If the consumer listed above is genuinely fine to break (e.g. it is" >&2
        echo "  itself dead code, or you already fixed it downstream), verify that" >&2
        echo "  by hand, then bypass once with: SKIP_CONSUMER_CHECK=1 git commit ..." >&2
        log "BLOCKED rc=$rc"
        exit 1 ;;
    (*)
        # 3 = INDETERMINATE, or anything unrecognised — warn, do not block.
        echo "pruned-script-consumer-check: INDETERMINATE (checker exited $rc) — not blocking, but the deletion below was NOT verified:" >&2
        echo "$out" >&2
        log "indeterminate rc=$rc"
        exit 0 ;;
esac
