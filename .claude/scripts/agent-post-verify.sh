#!/usr/bin/env bash
# agent-post-verify.sh — Tier 3 post-agent verification helper.
# Companion to the `auto-delegation` rule's "Tier 3 — Post-Agent Verification"
# section and JohnGavin/llm#191 / llm#304 / llm#318.
#
# Usage:
#   agent-post-verify.sh capture <repo-path> [--id <token>]
#       Capture the orchestrator's main HEAD AND current-branch HEAD, plus a
#       working-tree status hash.  State written to
#       /tmp/agent-post-verify-<REPO_NAME>-<ID>.txt
#       --id <token>  explicit dispatch ID (default: current PID; callers SHOULD
#                     pass a stable token so check can find the same state file)
#       Prints the state-file path to stdout so the caller can pass it to check.
#
#   agent-post-verify.sh check <repo-path> --id <token>
#       Read the captured state, compare to current HEAD/branch/status-hash for
#       BOTH main AND the orchestrator's working branch.  Exit 0 = no drift,
#       exit 1 = drift detected (recovery suggestions emitted).
#       A same-branch HEAD move that is a pure fast-forward to the remote-tracking
#       branch (e.g. a `pull --ff-only`) is benign: FAST_FORWARD_TO_REMOTE, exit 0.
#       Exit 3 = INDETERMINATE (HEAD moved, no usable remote-tracking ref).
#       Validates stored repo= matches argument.
#       Writes to ~/.claude/logs/worktree_post_verify.log.
#
# Why we snapshot the current branch too (#304 / #318):
#   A Tier-3 check that only snapshots `main` misses breaches where the agent
#   commits to the orchestrator's active session branch (a feat/cc-* worktree
#   branch) instead of to its own harness-worktree branch.  Snapshotting BOTH
#   lets us surface those breaches immediately.
#
# Recommended invocation pattern:
#   before dispatching an isolation:"worktree" agent:
#       STATE=$(agent-post-verify.sh capture /Users/johngavin/docs_gh/llmtelemetry --id "$DISPATCH_ID")
#   after the agent completes:
#       agent-post-verify.sh check /Users/johngavin/docs_gh/llmtelemetry --id "$DISPATCH_ID"
#
# Backward compatibility:
#   Existing capture/check call sites that only pass <repo-path> + --id continue
#   to work.  The extra current-branch fields are additive.
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
        # --- NEW (#304/#318): snapshot the orchestrator's current branch ---
        # When the orchestrator is on a feat/cc-* session branch, `branch` already
        # captures that value.  These explicit fields let check surface drift on
        # the session branch independently from drift on main.
        current_branch="$branch"
        current_head="$head"
        printf 'head=%s\nbranch=%s\nrepo=%s\nstatus_hash=%s\nis_dirty=%s\ncurrent_head=%s\ncurrent_branch=%s\ncaptured_at=%s\n' \
            "$head" "$branch" "$REPO" "$status_hash" "$is_dirty" \
            "$current_head" "$current_branch" \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$STATE_FILE"
        log "CAPTURE id=$DISPATCH_ID repo=$REPO head=$head branch=$branch current_head=$current_head current_branch=$current_branch status_hash=$status_hash is_dirty=$is_dirty"
        echo "Captured: head=$head branch=$branch current_branch=$current_branch is_dirty=$is_dirty"
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
        # --- NEW (#304/#318): read back the orchestrator's current-branch snapshot ---
        current_head_before=$(grep '^current_head=' "$STATE_FILE" | cut -d= -f2 || echo "")
        current_branch_before=$(grep '^current_branch=' "$STATE_FILE" | cut -d= -f2 || echo "")

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
        current_branch_ok=true
        current_head_ok=true
        [ "$head_before" != "$head_after" ] && head_ok=false
        [ "$branch_before" != "$branch_after" ] && branch_ok=false
        # Only compare status hash if we have a stored value (backwards compat)
        if [ -n "$status_hash_before" ] && [ "$status_hash_before" != "$status_hash_after" ]; then
            status_ok=false
        fi
        # --- NEW (#304/#318): check orchestrator's current branch hasn't moved ---
        # Only perform these checks when the stored fields are present (backward compat).
        if [ -n "$current_branch_before" ] && [ "$current_branch_before" != "$branch_after" ]; then
            current_branch_ok=false
        fi
        if [ -n "$current_head_before" ] && [ "$current_head_before" != "$head_after" ]; then
            current_head_ok=false
        fi

        if $head_ok && $branch_ok && $status_ok && $current_branch_ok && $current_head_ok; then
            log "CHECK id=$DISPATCH_ID OK head=$head_after branch=$branch_after current_branch=$branch_after status_hash=$status_hash_after"
            echo "OK: no drift (head=$head_after branch=$branch_after working-tree=clean)"
            rm -f "$STATE_FILE"
            exit 0
        fi

        # Drift detected — classify (original verdicts still apply; add two new ones)
        verdict="UNKNOWN"
        if ! $head_ok && $branch_ok; then
            verdict="HEAD_MOVED_SAME_BRANCH"
        elif ! $head_ok && ! $branch_ok; then
            verdict="HEAD_MOVED_BRANCH_CHANGED"
        elif $head_ok && ! $branch_ok; then
            verdict="BRANCH_CHANGED_NO_COMMITS"
        elif $head_ok && $branch_ok && ! $status_ok; then
            verdict="UNCOMMITTED_WRITES"
        elif ! $current_branch_ok; then
            # Agent switched the orchestrator away from its session branch (#304/#318)
            verdict="SESSION_BRANCH_SWITCHED"
        elif ! $current_head_ok; then
            # Agent committed to the orchestrator's session branch (#304/#318)
            verdict="SESSION_BRANCH_HEAD_MOVED"
        fi

        # --- Classify a same-branch HEAD move (fast-forward to remote is benign) ---
        # A `pull --ff-only` by the orchestrator or a scheduled job moves HEAD
        # but is not agent drift.  Uses the LOCAL remote-tracking ref (no fetch:
        # a check must not mutate the repo), so freshness depends on whoever
        # last fetched; a pull that moved HEAD has necessarily updated it.
        local_only_commits=""
        if [ "$verdict" = "HEAD_MOVED_SAME_BRANCH" ]; then
            remote_ref=$(git -C "$REPO" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) || remote_ref=""
            if [ -z "$remote_ref" ] && git -C "$REPO" rev-parse --verify -q "refs/remotes/origin/$branch_after" >/dev/null 2>&1; then
                remote_ref="origin/$branch_after"
            fi
            if [ -z "$remote_ref" ] \
               || ! git -C "$REPO" rev-parse --verify -q "$remote_ref^{commit}" >/dev/null 2>&1 \
               || ! git -C "$REPO" cat-file -e "$head_before^{commit}" 2>/dev/null; then
                log "CHECK id=$DISPATCH_ID INDETERMINATE head_before=$head_before head_after=$head_after branch=$branch_after remote_ref=${remote_ref:-none}"
                cat >&2 <<EOF
INDETERMINATE — HEAD moved on $branch_after ($head_before -> $head_after) but this
check cannot tell whether the move is a fast-forward to the remote: no usable
remote-tracking ref (found: ${remote_ref:-none}) or the old HEAD is not in the
object store.  NOT treating this as benign and NOT claiming drift.
  Inspect:  git -C $REPO reflog -5 $branch_after
            git -C $REPO log --oneline $head_before..$head_after
State file kept at: $STATE_FILE
EOF
                exit 3
            fi
            reflog_subject=$(git -C "$REPO" reflog -1 --format=%gs "$branch_after" 2>/dev/null) || reflog_subject=""
            if git -C "$REPO" merge-base --is-ancestor "$head_before" "$head_after" 2>/dev/null && $status_ok; then
                local_only_commits=$(git -C "$REPO" rev-list --oneline "$head_before..$head_after" --not "$remote_ref" 2>/dev/null) || local_only_commits=""
                if [ -z "$local_only_commits" ]; then
                    log "CHECK id=$DISPATCH_ID FAST_FORWARD_TO_REMOTE head_before=$head_before head_after=$head_after remote_ref=$remote_ref reflog='$reflog_subject'"
                    echo "FAST_FORWARD_TO_REMOTE (benign): $branch_after moved $head_before -> $head_after,"
                    echo "  a pure fast-forward and every new commit is on $remote_ref (local remote-tracking ref, no fetch)."
                    [ -n "$reflog_subject" ] && echo "  reflog evidence: $branch_after@{0}: $reflog_subject"
                    echo "  Commits:"
                    git -C "$REPO" log --oneline "$head_before..$head_after" | sed 's/^/    /'
                    rm -f "$STATE_FILE"
                    exit 0
                fi
            else
                # Non-fast-forward (history rewritten) or status also changed: real drift.
                local_only_commits=$(git -C "$REPO" rev-list --oneline "$head_before..$head_after" --not "$remote_ref" 2>/dev/null) || local_only_commits=""
            fi
        fi

        log "CHECK id=$DISPATCH_ID DRIFT verdict=$verdict head_before=$head_before head_after=$head_after branch_before=$branch_before branch_after=$branch_after current_head_before=$current_head_before current_branch_before=$current_branch_before status_hash_before=$status_hash_before status_hash_after=$status_hash_after"

        cat >&2 <<EOF
DRIFT DETECTED — verdict: $verdict
  Before: head=$head_before branch=$branch_before status_hash=$status_hash_before
  After:  head=$head_after branch=$branch_after status_hash=$status_hash_after

Recovery suggestions:
EOF

        case "$verdict" in
            HEAD_MOVED_SAME_BRANCH)
                cat >&2 <<EOF
  $branch_after moved and the move is NOT a plain fast-forward to the remote.
  Local-only commits (not on the remote-tracking branch; empty list means the
  history was rewritten rather than extended):
$(printf '%s\n' "$local_only_commits" | sed 's/^/    /')
  First preserve the work on a recovery branch (safe, non-destructive):
    git -C $REPO branch agent-recovery-$(date +%s) $head_after
  Do NOT run 'git reset --hard $head_before' until the user confirms: it is a
  destructive Class B op (destructive-ops-guard) and may discard merged work.
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
            SESSION_BRANCH_SWITCHED)
                # New: #304/#318 — agent switched the orchestrator's session branch
                cat >&2 <<EOF
  ISOLATION BREACH (#304/#318): Agent switched the orchestrator's working branch.
  Before dispatch: $current_branch_before   After: $branch_after
  This can happen via SendMessage continuations or a misbehaving agent.
  Switch back to the orchestrator's intended session branch:
    git -C $REPO checkout $current_branch_before
  Then review any commits on $branch_after before discarding.
EOF
                ;;
            SESSION_BRANCH_HEAD_MOVED)
                # New: #304/#318 — agent committed to the orchestrator's session branch
                cat >&2 <<EOF
  ISOLATION BREACH (#304/#318): Agent committed to the orchestrator's session
  branch '$current_branch_before' instead of its own harness-worktree branch.
  This is the SendMessage-continuation failure mode (see llm#304) or a sibling-
  worktree push failure (see llm#318).
  To preserve the work without contaminating the session branch:
    git -C $REPO branch agent-recovery-$(date +%s) $head_after
    git -C $REPO reset --hard $current_head_before
  Then cherry-pick from agent-recovery-* onto a fresh feature branch.
  IMPORTANT: do NOT use SendMessage to continue write-capable agents — dispatch
  a fresh isolation:"worktree" agent instead.
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
