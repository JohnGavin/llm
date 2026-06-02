#!/usr/bin/env bash
# clean-stale-worktrees.sh — Remove stale agent-internal worktrees from Claude Code projects.
#
# USAGE:
#   clean-stale-worktrees.sh [--dry-run] [--age=DUR] [--force-with-changes] <project-dir>
#   clean-stale-worktrees.sh --sweep [--dry-run] [--age=DUR] [--force-with-changes]
#
# ARGUMENTS:
#   --dry-run              Print what would be removed; do not remove anything.
#   --age=DUR              Minimum age before a worktree is eligible for removal.
#                          Format: Nd (days), Nh (hours), Ns (seconds). Default: 7d.
#   --force-with-changes   Remove worktrees even if they have uncommitted changes.
#   --sweep                Scan all git repos under ~/docs_gh/ (up to depth 5).
#
# TARGETS:
#   Only removes worktrees matching <project>/.claude/worktrees/agent-* pattern.
#   User-managed worktrees at ~/worktrees/<project>/<branch>/ are NEVER touched.
#
# LIVE RUN CONFIRMATION:
#   If 10 or more worktrees would be removed in a single live run, the env var
#   CLEAN_STALE_WORKTREES_CONFIRM="YES REMOVE STALE WORKTREES" must be set.
#
# LOGS:
#   Every removal is appended to ~/.claude/logs/clean-stale-worktrees.log
#
# SELFTEST:
#   CLAUDE_HOOK_SELFTEST=1 bash clean-stale-worktrees.sh
#
# Background (JohnGavin/llm#424):
#   Pre-flight scan found 170 agent worktrees globally (llm=65, historical=47,
#   micromort=27, llmtelemetry=20). 144 locked, 55 >=7d old. Default age 7d
#   balances removal scope vs. safety. Auto-GC via session_init (Part C, 14d
#   threshold) is deferred to a follow-up issue.

set -uo pipefail

# ── Constants ──────────────────────────────────────────────────────────────────
LOG_DIR="${HOME}/.claude/logs"
LOG_FILE="${LOG_DIR}/clean-stale-worktrees.log"
DOCS_BASE="${HOME}/docs_gh"

# ── Logging ────────────────────────────────────────────────────────────────────
log() {
    mkdir -p "$LOG_DIR"
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

emit() {
    printf '%s\n' "$*"
}

# ── Convert --age duration to seconds ─────────────────────────────────────────
age_to_seconds() {
    local DUR="$1"
    local NUM UNIT
    NUM=$(printf '%s' "$DUR" | sed 's/[^0-9]//g')
    UNIT=$(printf '%s' "$DUR" | sed 's/[0-9]//g')
    if [ -z "$NUM" ]; then
        printf 'ERROR: Cannot parse --age value: %s\n' "$DUR" >&2
        return 1
    fi
    case "$UNIT" in
        d) printf '%d' $(( NUM * 86400 )) ;;
        h) printf '%d' $(( NUM * 3600 )) ;;
        s) printf '%d' "$NUM" ;;
        *)
            printf 'ERROR: Unknown --age unit "%s" in "%s". Use d (days), h (hours), s (seconds).\n' "$UNIT" "$DUR" >&2
            return 1
            ;;
    esac
}

# ── Core per-worktree decision logic ──────────────────────────────────────────
# Arguments:
#   $1 = absolute path to the worktree directory
#   $2 = git common dir (.git for main checkout)
#   $3 = project root path
#   $4 = age threshold in seconds
#   $5 = force-with-changes flag (0 or 1)
# Outputs to stdout: "REMOVE" or "SKIP <reason>"
evaluate_worktree() {
    local WT_PATH="$1"
    local GIT_COMMON_DIR="$2"
    local PROJECT_ROOT="$3"
    local AGE_SEC="$4"
    local FORCE="$5"
    local NOW="$6"

    # Guard 1: Skip if path is the main checkout itself
    if [ "$WT_PATH" = "$PROJECT_ROOT" ]; then
        printf 'SKIP main-checkout'
        return
    fi

    # Guard 2: Only target agent-internal worktrees
    case "$WT_PATH" in
        */.claude/worktrees/agent-*)
            : # matches — continue evaluation
            ;;
        *)
            printf 'SKIP not-agent-worktree'
            return
            ;;
    esac

    # Guard 3: Skip if this is our current working directory
    local CURRENT_DIR
    CURRENT_DIR=$(pwd 2>/dev/null || true)
    if [ "$WT_PATH" = "$CURRENT_DIR" ]; then
        printf 'SKIP current-cwd'
        return
    fi

    # Derive the worktree name (git uses basename under .git/worktrees/)
    local WT_NAME
    WT_NAME=$(basename "$WT_PATH")

    # Guard 4: Owner-PID detection (best-effort)
    local LOCK_FILE="${GIT_COMMON_DIR}/worktrees/${WT_NAME}/locked"
    if [ -f "$LOCK_FILE" ]; then
        local LOCK_REASON
        LOCK_REASON=$(cat "$LOCK_FILE" 2>/dev/null || true)
        # Try to extract pid=NNN or bare integer
        local PID=""
        PID=$(printf '%s' "$LOCK_REASON" | grep -oE 'pid=[0-9]+' | grep -oE '[0-9]+' | head -n1 || true)
        if [ -z "$PID" ]; then
            PID=$(printf '%s' "$LOCK_REASON" | grep -oE '^[0-9]+$' | head -n1 || true)
        fi
        if [ -n "$PID" ]; then
            if kill -0 "$PID" 2>/dev/null; then
                printf 'SKIP owner-pid-%s-alive' "$PID"
                return
            fi
            # PID found but dead — fall through to age check
        fi
        # No parseable PID — fall through to age check (best-effort)
    fi

    # Guard 5: Age check.
    # PREFER the locked file's mtime over the meta-dir mtime — the meta-dir
    # gets bumped by routine `git status` calls (including this script's own
    # Guard 6 below), making the dir mtime worthless for distinguishing
    # actually-stale worktrees from ones we just probed. The `locked` file
    # only changes when the worktree is (un)locked, which is a meaningful
    # signal of "last real activity". Fall back to dir mtime if no lock file.
    local GITDIR_FOR_WT="${GIT_COMMON_DIR}/worktrees/${WT_NAME}"
    if [ ! -d "$GITDIR_FOR_WT" ]; then
        printf 'SKIP no-gitdir-metadata'
        return
    fi

    local WT_MTIME
    if [ -f "${GITDIR_FOR_WT}/locked" ]; then
        WT_MTIME=$(stat -f '%m' "${GITDIR_FOR_WT}/locked" 2>/dev/null || printf '0')
    else
        WT_MTIME=$(stat -f '%m' "$GITDIR_FOR_WT" 2>/dev/null || printf '0')
    fi
    local WT_AGE=$(( NOW - WT_MTIME ))

    if [ "$WT_AGE" -lt "$AGE_SEC" ]; then
        printf 'SKIP too-recent-%ds' "$WT_AGE"
        return
    fi

    # Guard 6: Uncommitted-changes check
    if [ -d "$WT_PATH" ]; then
        local STATUS_OUTPUT
        STATUS_OUTPUT=$(git -C "$WT_PATH" status --short 2>/dev/null || true)
        if [ -n "$STATUS_OUTPUT" ]; then
            if [ "$FORCE" = "0" ]; then
                printf 'SKIP has-uncommitted-changes'
                return
            fi
            # FORCE=1 — will remove anyway (noted in log)
        fi
    fi

    printf 'REMOVE'
}

# ── Remove a single worktree ──────────────────────────────────────────────────
remove_worktree() {
    local WT_PATH="$1"
    local PROJECT_ROOT="$2"
    local DRY="$3"

    if [ "$DRY" = "1" ]; then
        emit "[dry-run] WOULD REMOVE: ${WT_PATH}"
        return 0
    fi

    # Unlock first (ignore errors — may already be unlocked)
    git -C "$PROJECT_ROOT" worktree unlock "$WT_PATH" 2>/dev/null || true
    # Force remove
    if git -C "$PROJECT_ROOT" worktree remove --force "$WT_PATH" 2>/dev/null; then
        emit "REMOVED: ${WT_PATH}"
        log "REMOVED project=${PROJECT_ROOT} worktree=${WT_PATH}"
        return 0
    else
        emit "WARN: failed to remove ${WT_PATH} — manual cleanup may be needed"
        log "REMOVE-FAILED project=${PROJECT_ROOT} worktree=${WT_PATH}"
        return 1
    fi
}

# ── Process a single project directory ────────────────────────────────────────
process_project() {
    local PROJ_ROOT="$1"
    local AGE_SEC="$2"
    local DRY="$3"
    local FORCE="$4"
    local NOW="$5"
    local AGENT_WT_DIR="${PROJ_ROOT}/.claude/worktrees"

    if [ ! -d "$AGENT_WT_DIR" ]; then
        return 0
    fi

    # Find the main .git directory
    local GIT_COMMON_DIR
    GIT_COMMON_DIR=$(git -C "$PROJ_ROOT" rev-parse --git-common-dir 2>/dev/null || true)
    if [ -z "$GIT_COMMON_DIR" ]; then
        return 0
    fi
    # Make absolute if relative
    case "$GIT_COMMON_DIR" in
        /*) : ;;
        *) GIT_COMMON_DIR="${PROJ_ROOT}/${GIT_COMMON_DIR}" ;;
    esac

    # Single pass: evaluate every worktree, collect candidates, emit SKIP lines.
    # Caching the decision avoids a re-evaluation race where `git status` (Guard 6)
    # bumps the worktree-meta dir mtime between passes, causing it to flip from
    # REMOVE → SKIP too-recent on the second evaluation.
    local REMOVE_COUNT=0
    local SKIP_COUNT=0
    local WT_PATH
    local CANDIDATES_FILE
    CANDIDATES_FILE=$(mktemp /tmp/cwt_candidates_XXXXXX)
    # shellcheck disable=SC2064
    trap "rm -f '$CANDIDATES_FILE'" RETURN

    while IFS= read -r WT_PATH; do
        [ -n "$WT_PATH" ] || continue
        local DECISION
        DECISION=$(evaluate_worktree "$WT_PATH" "$GIT_COMMON_DIR" "$PROJ_ROOT" "$AGE_SEC" "$FORCE" "$NOW")
        case "$DECISION" in
            REMOVE)
                REMOVE_COUNT=$(( REMOVE_COUNT + 1 ))
                printf '%s\n' "$WT_PATH" >> "$CANDIDATES_FILE"
                if [ "$DRY" = "1" ]; then
                    emit "[dry-run] WOULD REMOVE: ${WT_PATH}"
                fi
                ;;
            SKIP*)
                SKIP_COUNT=$(( SKIP_COUNT + 1 ))
                local REASON="${DECISION#SKIP }"
                emit "SKIP [${REASON}]: ${WT_PATH}"
                ;;
        esac
    done < <(find "$AGENT_WT_DIR" -maxdepth 1 -mindepth 1 -type d -name "agent-*" 2>/dev/null)

    # Confirmation for large live removals
    if [ "$REMOVE_COUNT" -ge 10 ] && [ "$DRY" = "0" ]; then
        if [ "${CLEAN_STALE_WORKTREES_CONFIRM:-}" != "YES REMOVE STALE WORKTREES" ]; then
            emit ""
            emit "CONFIRMATION REQUIRED: ${REMOVE_COUNT} worktrees would be removed from ${PROJ_ROOT}."
            emit "Set env var to proceed:"
            emit '  CLEAN_STALE_WORKTREES_CONFIRM="YES REMOVE STALE WORKTREES" clean-stale-worktrees.sh ...'
            emit "Or use --dry-run to see the list without removing."
            return 1
        fi
    fi

    # Live removal pass: read paths cached above, no re-evaluation
    if [ "$DRY" = "0" ]; then
        while IFS= read -r WT_PATH; do
            [ -n "$WT_PATH" ] || continue
            remove_worktree "$WT_PATH" "$PROJ_ROOT" "$DRY"
        done < "$CANDIDATES_FILE"
    fi

    if [ "$REMOVE_COUNT" -gt 0 ] || [ "$SKIP_COUNT" -gt 0 ]; then
        emit ""
        emit "Project: ${PROJ_ROOT}"
        if [ "$DRY" = "1" ]; then
            emit "  Would remove: ${REMOVE_COUNT}  Skipped: ${SKIP_COUNT}"
        else
            emit "  Removed: ${REMOVE_COUNT}  Skipped: ${SKIP_COUNT}"
        fi
    fi
}

# ── Selftest ──────────────────────────────────────────────────────────────────
run_selftest() {
    local SCRIPT_PATH="$1"
    emit "=== clean-stale-worktrees.sh selftest ==="

    # Prevent infinite recursion: child bash invocations would inherit the
    # selftest flag and re-enter this block. Same fix as #354 needed here.
    unset CLAUDE_HOOK_SELFTEST

    local PASS=0
    local FAIL=0
    local TMPDIR
    TMPDIR=$(mktemp -d /tmp/cwt_selftest_XXXXXX)
    # shellcheck disable=SC2064
    trap "rm -rf '$TMPDIR'" EXIT

    # Create a minimal git repo that acts as the "project"
    local PROJ="${TMPDIR}/myproject"
    mkdir -p "$PROJ"
    git -C "$PROJ" init -q
    git -C "$PROJ" config user.email "test@test.com"
    git -C "$PROJ" config user.name "Test"
    touch "${PROJ}/README"
    git -C "$PROJ" add README
    git -C "$PROJ" commit -q -m "init"

    # Create the agent worktrees directory
    local WT_BASE="${PROJ}/.claude/worktrees"
    mkdir -p "$WT_BASE"

    # WT1: recent (within any reasonable age) — should be SKIPPED
    git -C "$PROJ" worktree add -q "${WT_BASE}/agent-recent" -b "wt-recent"

    # WT2: old, no uncommitted changes — should be REMOVED
    git -C "$PROJ" worktree add -q "${WT_BASE}/agent-old-clean" -b "wt-old-clean"
    local GIT_DIR="${PROJ}/.git"
    touch -t 202001010000 "${GIT_DIR}/worktrees/agent-old-clean" 2>/dev/null || true

    # WT3: old, has uncommitted changes — should be SKIPPED without --force-with-changes
    git -C "$PROJ" worktree add -q "${WT_BASE}/agent-old-dirty" -b "wt-old-dirty"
    touch -t 202001010000 "${GIT_DIR}/worktrees/agent-old-dirty" 2>/dev/null || true
    printf 'dirty\n' > "${WT_BASE}/agent-old-dirty/dirty.txt"

    # Test 1: dry-run — old-clean = WOULD REMOVE
    local DRY_OUT
    DRY_OUT=$(bash "$SCRIPT_PATH" --dry-run "--age=1s" "$PROJ" 2>/dev/null)

    if printf '%s' "$DRY_OUT" | grep -q "WOULD REMOVE.*agent-old-clean"; then
        PASS=$(( PASS + 1 ))
        emit "PASS 1/6: dry-run shows agent-old-clean as WOULD REMOVE"
    else
        FAIL=$(( FAIL + 1 ))
        emit "FAIL 1/6: expected agent-old-clean in dry-run output"
        emit "  Output was: $DRY_OUT"
    fi

    # Test 2: dry-run — old-dirty = SKIP
    if printf '%s' "$DRY_OUT" | grep -q "SKIP.*agent-old-dirty"; then
        PASS=$(( PASS + 1 ))
        emit "PASS 2/6: dry-run skips agent-old-dirty (has changes)"
    else
        FAIL=$(( FAIL + 1 ))
        emit "FAIL 2/6: expected agent-old-dirty to be SKIP in dry-run"
        emit "  Output was: $DRY_OUT"
    fi

    # Test 3: dry-run — recent NOT in removal list
    if ! printf '%s' "$DRY_OUT" | grep -q "WOULD REMOVE.*agent-recent"; then
        PASS=$(( PASS + 1 ))
        emit "PASS 3/6: dry-run does not mark agent-recent for removal"
    else
        FAIL=$(( FAIL + 1 ))
        emit "FAIL 3/6: agent-recent should NOT be in removal list"
    fi

    # Re-touch the meta-dir mtimes — the prior dry-run invocation called git
    # status which writes lock files inside .git/worktrees/<name>/ and bumps
    # the dir mtime, making the worktree look "too-recent" on the next pass.
    touch -t 202001010000 "${GIT_DIR}/worktrees/agent-old-clean" 2>/dev/null || true
    touch -t 202001010000 "${GIT_DIR}/worktrees/agent-old-dirty" 2>/dev/null || true

    # Test 4 & 5: live run without --force-with-changes
    bash "$SCRIPT_PATH" "--age=1s" "$PROJ" > /dev/null 2>&1 || true

    if [ -d "${WT_BASE}/agent-old-dirty" ]; then
        PASS=$(( PASS + 1 ))
        emit "PASS 4/6: agent-old-dirty NOT removed in live run without --force-with-changes"
    else
        FAIL=$(( FAIL + 1 ))
        emit "FAIL 4/6: agent-old-dirty was removed but should have been skipped"
    fi

    if [ ! -d "${WT_BASE}/agent-old-clean" ]; then
        PASS=$(( PASS + 1 ))
        emit "PASS 5/6: agent-old-clean was removed in live run"
    else
        FAIL=$(( FAIL + 1 ))
        emit "FAIL 5/6: agent-old-clean still present after live run"
    fi

    # Re-touch before final invocation for the same mtime-bump reason
    touch -t 202001010000 "${GIT_DIR}/worktrees/agent-old-dirty" 2>/dev/null || true

    # Test 6: live run WITH --force-with-changes — old-dirty now removed
    bash "$SCRIPT_PATH" "--age=1s" --force-with-changes "$PROJ" > /dev/null 2>&1 || true

    if [ ! -d "${WT_BASE}/agent-old-dirty" ]; then
        PASS=$(( PASS + 1 ))
        emit "PASS 6/6: agent-old-dirty removed with --force-with-changes"
    else
        FAIL=$(( FAIL + 1 ))
        emit "FAIL 6/6: agent-old-dirty still present despite --force-with-changes"
    fi

    emit ""
    emit "${PASS}/$(( PASS + FAIL )) PASS"
    if [ "$FAIL" -gt 0 ]; then
        return 1
    fi
    return 0
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    local SCRIPT_PATH
    SCRIPT_PATH=$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")

    # Selftest mode — must run before argument validation
    if [ "${CLAUDE_HOOK_SELFTEST:-}" = "1" ]; then
        run_selftest "$SCRIPT_PATH"
        exit $?
    fi

    # Parse arguments
    local DRY_RUN=0
    local FORCE_WITH_CHANGES=0
    local SWEEP=0
    local AGE_STR="7d"
    local PROJECT_DIR=""

    for arg in "$@"; do
        case "$arg" in
            --dry-run)
                DRY_RUN=1
                ;;
            --force-with-changes)
                FORCE_WITH_CHANGES=1
                ;;
            --sweep)
                SWEEP=1
                ;;
            --age=*)
                AGE_STR="${arg#--age=}"
                ;;
            --validate-config)
                printf 'ERROR: --validate-config belongs to cc-worktree.sh, not clean-stale-worktrees.sh\n' >&2
                printf 'Use: ~/.claude/scripts/cc-worktree.sh --validate-config\n' >&2
                exit 1
                ;;
            -*)
                printf 'ERROR: Unknown flag: %s\n' "$arg" >&2
                exit 1
                ;;
            *)
                if [ -n "$PROJECT_DIR" ]; then
                    printf 'ERROR: Multiple positional arguments supplied.\n' >&2
                    exit 1
                fi
                PROJECT_DIR="$arg"
                ;;
        esac
    done

    # Validate
    if [ "$SWEEP" = "0" ] && [ -z "$PROJECT_DIR" ]; then
        printf 'USAGE: clean-stale-worktrees.sh [--dry-run] [--age=DUR] [--force-with-changes] <project-dir>\n' >&2
        printf '       clean-stale-worktrees.sh --sweep [--dry-run] [--age=DUR] [--force-with-changes]\n' >&2
        exit 1
    fi

    if [ "$SWEEP" = "1" ] && [ -n "$PROJECT_DIR" ]; then
        printf 'ERROR: --sweep and <project-dir> are mutually exclusive.\n' >&2
        exit 1
    fi

    local AGE_SECONDS
    AGE_SECONDS=$(age_to_seconds "$AGE_STR") || exit 1

    local NOW
    NOW=$(date +%s)

    if [ "$SWEEP" = "1" ]; then
        emit "Sweeping all projects under ${DOCS_BASE} (age >= ${AGE_STR})..."
        emit ""
        local GIT_DIR LOCAL_PROJ
        while IFS= read -r GIT_DIR; do
            LOCAL_PROJ=$(dirname "$GIT_DIR")
            # Skip if .git is a file (worktree, not main checkout)
            if [ -f "${LOCAL_PROJ}/.git" ]; then
                continue
            fi
            process_project "$LOCAL_PROJ" "$AGE_SECONDS" "$DRY_RUN" "$FORCE_WITH_CHANGES" "$NOW"
        done < <(find "$DOCS_BASE" -maxdepth 5 -name ".git" -type d -prune 2>/dev/null)
    else
        if [ ! -d "$PROJECT_DIR" ]; then
            printf 'ERROR: Project directory not found: %s\n' "$PROJECT_DIR" >&2
            exit 1
        fi
        PROJECT_DIR=$(cd "$PROJECT_DIR" 2>/dev/null && pwd)
        emit "Scanning project: ${PROJECT_DIR} (age >= ${AGE_STR})..."
        emit ""
        process_project "$PROJECT_DIR" "$AGE_SECONDS" "$DRY_RUN" "$FORCE_WITH_CHANGES" "$NOW"
    fi
}

main "$@"
