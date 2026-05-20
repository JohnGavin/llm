#!/usr/bin/env bash
# agent-post-verify.sh — Tier 3 post-agent verification helper.
# Companion to the `auto-delegation` rule's "Tier 3 — Post-Agent Verification"
# section and JohnGavin/llm#191.
#
# Usage:
#   agent-post-verify.sh capture <repo-path> [tag]
#       Capture current main HEAD + branch to /tmp/agent-post-verify-<tag>.txt
#       Default tag = basename of repo-path.
#
#   agent-post-verify.sh check <repo-path> [tag]
#       Read the captured state, compare to current. Exit 0 = no drift,
#       exit 1 = drift detected (auto-recovery suggested).
#       Writes to ~/.claude/logs/worktree_post_verify.log.
#
# Recommended invocation pattern:
#   before dispatching an isolation:"worktree" agent:
#       agent-post-verify.sh capture /Users/johngavin/docs_gh/llmtelemetry
#   after the agent completes:
#       agent-post-verify.sh check /Users/johngavin/docs_gh/llmtelemetry

set -e

LOG_DIR="$HOME/.claude/logs"
LOG_FILE="$LOG_DIR/worktree_post_verify.log"
mkdir -p "$LOG_DIR"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"
}

usage() {
    cat >&2 <<'EOF'
Usage:
  agent-post-verify.sh capture <repo-path> [tag]
  agent-post-verify.sh check <repo-path> [tag]
EOF
    exit 2
}

if [ $# -lt 2 ]; then
    usage
fi

MODE="$1"
REPO="$2"
TAG="${3:-$(basename "$REPO")}"
STATE_FILE="/tmp/agent-post-verify-${TAG}.txt"

if ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
    echo "ERROR: $REPO is not a git repository" >&2
    exit 2
fi

case "$MODE" in
    capture)
        head=$(git -C "$REPO" rev-parse HEAD)
        branch=$(git -C "$REPO" rev-parse --abbrev-ref HEAD)
        printf 'head=%s\nbranch=%s\nrepo=%s\ncaptured_at=%s\n' \
            "$head" "$branch" "$REPO" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$STATE_FILE"
        log "CAPTURE tag=$TAG repo=$REPO head=$head branch=$branch"
        echo "Captured: head=$head branch=$branch"
        echo "State file: $STATE_FILE"
        ;;

    check)
        if [ ! -f "$STATE_FILE" ]; then
            echo "ERROR: no captured state at $STATE_FILE — call capture first" >&2
            exit 2
        fi

        head_before=$(grep '^head=' "$STATE_FILE" | cut -d= -f2)
        branch_before=$(grep '^branch=' "$STATE_FILE" | cut -d= -f2)

        head_after=$(git -C "$REPO" rev-parse HEAD)
        branch_after=$(git -C "$REPO" rev-parse --abbrev-ref HEAD)

        if [ "$head_before" = "$head_after" ] && [ "$branch_before" = "$branch_after" ]; then
            log "CHECK tag=$TAG OK head=$head_after branch=$branch_after"
            echo "OK: no drift (head=$head_after branch=$branch_after)"
            rm -f "$STATE_FILE"
            exit 0
        fi

        # Drift detected — classify
        verdict="UNKNOWN"
        if [ "$head_before" != "$head_after" ] && [ "$branch_before" = "$branch_after" ]; then
            verdict="HEAD_MOVED_SAME_BRANCH"
        elif [ "$head_before" != "$head_after" ] && [ "$branch_before" != "$branch_after" ]; then
            verdict="HEAD_MOVED_BRANCH_CHANGED"
        elif [ "$head_before" = "$head_after" ] && [ "$branch_before" != "$branch_after" ]; then
            verdict="BRANCH_CHANGED_NO_COMMITS"
        fi

        log "CHECK tag=$TAG DRIFT verdict=$verdict head_before=$head_before head_after=$head_after branch_before=$branch_before branch_after=$branch_after"

        cat >&2 <<EOF
DRIFT DETECTED — verdict: $verdict
  Before: head=$head_before branch=$branch_before
  After:  head=$head_after branch=$branch_after

Recovery suggestions:
EOF

        case "$verdict" in
            HEAD_MOVED_SAME_BRANCH)
                cat >&2 <<EOF
  Agent committed directly to $branch_after. To preserve the work on a
  feature branch and reset $branch_after:
    git -C $REPO branch agent-recovery-$(date +%s) $head_after
    git -C $REPO reset --hard $head_before
  Then cherry-pick from agent-recovery-* onto the intended target branch.
EOF
                ;;
            HEAD_MOVED_BRANCH_CHANGED)
                cat >&2 <<EOF
  Agent switched + committed. The commit is on $branch_after (probably correct).
  Switch the main checkout back to $branch_before:
    git -C $REPO checkout $branch_before
  Then merge or cherry-pick from $branch_after.
EOF
                ;;
            BRANCH_CHANGED_NO_COMMITS)
                cat >&2 <<EOF
  Agent switched branches without committing. No data loss. Just switch back:
    git -C $REPO checkout $branch_before
EOF
                ;;
        esac

        # Keep the state file for inspection
        echo "" >&2
        echo "State file kept at: $STATE_FILE" >&2
        exit 1
        ;;

    *)
        usage
        ;;
esac
