#!/usr/bin/env bash
# roborev_auto_refine.sh — Event-driven auto-refine daemon
# Listens to roborev stream, triggers refine when reviews complete with findings
#
# Usage:
#   ~/.claude/scripts/roborev_auto_refine.sh start   # Start in background
#   ~/.claude/scripts/roborev_auto_refine.sh stop    # Stop daemon
#   ~/.claude/scripts/roborev_auto_refine.sh status  # Check if running
#
# Logs: ~/.claude/logs/roborev-auto-refine.log

set -euo pipefail

# Mark session as scheduled/automated for llmtelemetry_emit.sh (#322 Phase 2).
# Propagates to any claude process spawned by roborev refine so the Stop hook
# emits "trigger":"scheduled" without requiring a /bye sentinel.
export CLAUDE_TRIGGER="${CLAUDE_TRIGGER:-scheduled}"

PIDFILE="$HOME/.claude/roborev-auto-refine.pid"
LOGFILE="$HOME/.claude/logs/roborev-auto-refine.log"
ROBOREV="/usr/local/bin/roborev"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOGFILE"; }

run_listener() {
    log "Starting auto-refine listener"

    # On startup, clear any existing backlog (one-time)
    log "Clearing existing backlog on startup..."
    "$ROBOREV" refine --min-severity high --max-iterations 10 --quiet >> "$LOGFILE" 2>&1 || true
    log "Initial backlog clear complete"

    # Stream events, filter for completed reviews with findings
    "$ROBOREV" stream 2>/dev/null | while IFS= read -r line; do
        # Parse event type, status, and job kind
        event_type=$(echo "$line" | /usr/bin/jq -r '.type // empty' 2>/dev/null)
        status=$(echo "$line" | /usr/bin/jq -r '.status // empty' 2>/dev/null)
        job_id=$(echo "$line" | /usr/bin/jq -r '.job_id // empty' 2>/dev/null)
        repo=$(echo "$line" | /usr/bin/jq -r '.repo // empty' 2>/dev/null)
        job_kind=$(echo "$line" | /usr/bin/jq -r '.kind // .job_kind // empty' 2>/dev/null)

        # Only trigger refine for original review jobs with an explicit "review" kind.
        # Any other kind (refine, fix, scan, or unknown) is skipped to prevent
        # background churn from unrelated job failures (fixes roborev #679).
        if [[ "$event_type" == "job_completed" && "$status" == "failed" && "$job_kind" == "review" ]]; then
            log "Review $job_id failed in $repo — triggering refine"

            # Run refine in background for that repo, max 2 iterations per trigger
            (
                cd "$repo" 2>/dev/null || exit 0
                "$ROBOREV" refine --max-iterations 2 --min-severity high --quiet >> "$LOGFILE" 2>&1
                log "Refine completed for $repo"
            ) &
        fi
    done
}

case "${1:-status}" in
    run)
        # Foreground mode for launchd — runs until killed
        mkdir -p "$(dirname "$LOGFILE")"
        log "Running in foreground (launchd mode)"
        run_listener
        ;;
    start)
        if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
            echo "Already running (PID $(cat "$PIDFILE"))"
            exit 0
        fi
        mkdir -p "$(dirname "$LOGFILE")"
        run_listener &
        echo $! > "$PIDFILE"
        echo "Started (PID $!). Logs: $LOGFILE"
        ;;
    stop)
        if [[ -f "$PIDFILE" ]]; then
            pid=$(cat "$PIDFILE")
            if kill -0 "$pid" 2>/dev/null; then
                kill "$pid"
                rm -f "$PIDFILE"
                echo "Stopped (was PID $pid)"
            else
                rm -f "$PIDFILE"
                echo "Not running (stale pidfile removed)"
            fi
        else
            echo "Not running"
        fi
        ;;
    status)
        if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
            echo "Running (PID $(cat "$PIDFILE"))"
        else
            echo "Not running"
        fi
        ;;
    *)
        echo "Usage: $0 {run|start|stop|status}"
        exit 1
        ;;
esac
