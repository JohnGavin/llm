#!/usr/bin/env bash
# agent-post-verify.sh — Tier 3 post-agent verification helper.
# Companion to the `auto-delegation` rule's "Tier 3 — Post-Agent Verification"
# section and JohnGavin/llm#191.
#
# Usage:
#   agent-post-verify.sh capture <repo-path> [--id <token>]
#       Capture current main HEAD, branch, and working-tree status hash.
#       State written to /tmp/agent-post-verify-<REPO_NAME>-<ID>.txt
#       --id <token>  explicit dispatch ID (default: $PPID for simple usage,
#                     but callers should pass a stable token so check can find it)
#       Prints the state-file path to stdout so the caller can pass it to check.
#
#   agent-post-verify.sh check <repo-path> --id <token>
#       Read the captured state, compare to current HEAD, branch, and working-tree
#       status hash. Exit 0 = no drift, exit 1 = drift detected (auto-recovery
#       suggested). Validates stored repo= matches argument.
#       Writes to ~/.claude/logs/worktree_post_verify.log.
#
# Recommended invocation pattern:
#   before dispatching an isolation:"worktree" agent:
#       STATE=$(agent-post-verify.sh capture /Users/johngavin/docs_gh/llmtelemetry --id "$DISPATCH_ID")
#   after the agent completes:
#       agent-post-verify.sh check /Users/johngavin/docs_gh/llmtelemetry --id "$DISPATCH_ID"
#
# Dirty-worktree detection:
#   The script captures a hash of `git status --porcelain` output at capture time.
#   On check, if the porcelain hash differs from the captured value, the working
#   tree has been modified since capture — treated as drift even if HEAD/branch
#   are unchanged.

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
  agent-post-verify.sh capture <repo-path> [--id <token>]
  agent-post-verify.sh check   <repo-path> --id <token>

Options:
  --id <token>   Unique dispatch identifier (avoids state-file collision
                 across concurrent agent dispatches). If omitted on capture,
                 defaults to the current PID; if omitted on check, the check
                 will fail because the state file name cannot be derived.
EOF
    exit 2
}

if [ $# -lt 2 ]; then
    usage
fi

MODE="$1"
REPO="$2"
shift 2

# Parse optional --id argument from remaining args
DISPATCH_ID=""
while [ $# -gt 0 ]; do
    case "$1" in
        --id) DISPATCH_ID="$2"; shift 2 ;;
        *)    echo "Unknown option: $1" >&2; usage ;;
    esac
done

REPO_NAME=$(basename "$REPO")

if [ "$MODE" = "capture" ]; then
    # On capture, default to current PID if no --id supplied
    DISPATCH_ID="${DISPATCH_ID:-$$}"
elif [ "$MODE" = "check" ]; then
    # On check, --id is required
    if [ -z "$DISPATCH_ID" ]; then
        echo "ERROR: 'check' requires --id <token>" >&2
        usage
    fi
fi

STATE_FILE="/tmp/agent-post-verify-${REPO_NAME}-${DISPATCH_ID}.txt"

if ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
    echo "ERROR: $REPO is not a git repository" >&2
    exit 2
fi

case "$MODE" in
    capture)
        head=$(git -C "$REPO" rev-parse HEAD)
        branch=$(git -C "$REPO" rev-parse --abbrev-ref HEAD)
        # Capture a hash of the working-tree status so uncommitted agent writes
        # are detected even when HEAD/branch are unchanged (C1 High fix).
        porcelain=$(git -C "$REPO" status --porcelain 2>/dev/null)
        # Use md5 if available, else fall back to cksum (both portable on macOS/Linux)
        if command -v md5sum >/dev/null 2>&1; then
            status_hash=$(echo "$porcelain" | md5sum | awk '{print $1}')
        elif command -v md5 >/dev/null 2>&1; then
            status_hash=$(echo "$porcelain" | md5)
        else
            status_hash=$(echo "$porcelain" | cksum | awk '{print $1}')
        fi
        is_dirty=0
        [ -n "$porcelain" ] && is_dirty=1
        printf 'head=%s\nbranch=%s\nrepo=%s\nstatus_hash=%s\nis_dirty=%s\ncaptured_at=%s\n' \
            "$head" "$branch" "$REPO" "$status_hash" "$is_dirty" \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$STATE_FILE"
        log "CAPTURE id=$DISPATCH_ID repo=$REPO head=$head branch=$branch status_hash=$status_hash is_dirty=$is_dirty"
        echo "Captured: head=$head branch=$branch is_dirty=$is_dirty"
        echo "State file: $STATE_FILE"
        ;;

    check)
        if [ ! -f "$STATE_FILE" ]; then
            echo "ERROR: no captured state at $STATE_FILE — call capture first with matching --id" >&2
            exit 2
        fi

        # Validate repo= stored in the state file matches the argument (C1 Medium fix).
        # Prevents silently using a state file from a different repo captured with the same ID.
        stored_repo=$(grep '^repo=' "$STATE_FILE" | cut -d= -f2-)
        if [ "$stored_repo" != "$REPO" ]; then
            echo "ERROR: state file repo mismatch — stored='$stored_repo' but argument='$REPO'" >&2
            echo "  If this is intentional, delete $STATE_FILE first." >&2
            exit 2
        fi

        head_before=$(grep '^head=' "$STATE_FILE" | cut -d= -f2)
        branch_before=$(grep '^branch=' "$STATE_FILE" | cut -d= -f2)
        status_hash_before=$(grep '^status_hash=' "$STATE_FILE" | cut -d= -f2 || echo "")

        head_after=$(git -C "$REPO" rev-parse HEAD)
        branch_after=$(git -C "$REPO" rev-parse --abbrev-ref HEAD)

        # Recompute current working-tree status hash (C1 High fix — detect uncommitted writes).
        porcelain_after=$(git -C "$REPO" status --porcelain 2>/dev/null)
        if command -v md5sum >/dev/null 2>&1; then
            status_hash_after=$(echo "$porcelain_after" | md5sum | awk '{print $1}')
        elif command -v md5 >/dev/null 2>&1; then
            status_hash_after=$(echo "$porcelain_after" | md5)
        else
            status_hash_after=$(echo "$porcelain_after" | cksum | awk '{print $1}')
        fi

        head_ok=true
        branch_ok=true
        status_ok=true
        [ "$head_before" != "$head_after" ] && head_ok=false
        [ "$branch_before" != "$branch_after" ] && branch_ok=false
        # Only compare status hash if we have a stored value (backwards compat)
        if [ -n "$status_hash_before" ] && [ "$status_hash_before" != "$status_hash_after" ]; then
            status_ok=false
        fi

        if $head_ok && $branch_ok && $status_ok; then
            log "CHECK id=$DISPATCH_ID OK head=$head_after branch=$branch_after status_hash=$status_hash_after"
            echo "OK: no drift (head=$head_after branch=$branch_after working-tree=clean)"
            rm -f "$STATE_FILE"
            exit 0
        fi

        # Drift detected — classify
        verdict="UNKNOWN"
        if ! $head_ok && $branch_ok; then
            verdict="HEAD_MOVED_SAME_BRANCH"
        elif ! $head_ok && ! $branch_ok; then
            verdict="HEAD_MOVED_BRANCH_CHANGED"
        elif $head_ok && ! $branch_ok; then
            verdict="BRANCH_CHANGED_NO_COMMITS"
        elif $head_ok && $branch_ok && ! $status_ok; then
            verdict="UNCOMMITTED_WRITES"
        fi

        log "CHECK id=$DISPATCH_ID DRIFT verdict=$verdict head_before=$head_before head_after=$head_after branch_before=$branch_before branch_after=$branch_after status_hash_before=$status_hash_before status_hash_after=$status_hash_after"

        cat >&2 <<EOF
DRIFT DETECTED — verdict: $verdict
  Before: head=$head_before branch=$branch_before status_hash=$status_hash_before
  After:  head=$head_after branch=$branch_after status_hash=$status_hash_after

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
            UNCOMMITTED_WRITES)
                cat >&2 <<EOF
  Agent made uncommitted changes to the working tree in $REPO (HEAD and branch
  are unchanged). Review with:
    git -C $REPO diff
    git -C $REPO status
  If changes are unintended, discard with (CONFIRM before running):
    git -C $REPO checkout -- .
  If changes are intentional, commit them to a feature branch before proceeding.
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
