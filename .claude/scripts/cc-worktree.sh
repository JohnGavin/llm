#!/usr/bin/env bash
# cc-worktree.sh — Create a git worktree at ~/worktrees/<project>/<branch>/
#
# Usage: cc-worktree.sh [--dry-run] <project-name> <branch-name> [base-branch]
#
# Arguments:
#   --dry-run      Print commands without executing them
#   project-name   Basename of a git repo under ~/docs_gh/ (searched recursively,
#                  max depth 3)
#   branch-name    Branch to create (will be created from base-branch)
#   base-branch    Branch to base new branch on (default: main)
#
# Convention (worktree-location rule):
#   All worktrees go under ~/worktrees/<project>/<branch>/
#
# Logs to: ~/.claude/logs/cc-worktree.log
#
# Exit codes:
#   0  Success (or --dry-run printed commands)
#   1  Usage error
#   2  Project not found under ~/docs_gh/
#   3  Worktree target path already exists
#   4  Branch already exists in the project repo
#   5  git worktree add failed

set -euo pipefail

# ── Constants ──────────────────────────────────────────────────────────────────
LOG_DIR="$HOME/.claude/logs"
LOG_FILE="$LOG_DIR/cc-worktree.log"
WORKTREES_BASE="$HOME/worktrees"
DOCS_BASE="$HOME/docs_gh"
SEARCH_MAXDEPTH=3

# ── Logging ────────────────────────────────────────────────────────────────────
log() {
    mkdir -p "$LOG_DIR"
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
    printf '%s\n' "$*" >&2
}

# ── Parse arguments ────────────────────────────────────────────────────────────
DRY_RUN=0
POSITIONAL=""

for arg in "$@"; do
    case "$arg" in
        --dry-run)
            DRY_RUN=1
            ;;
        *)
            POSITIONAL="${POSITIONAL} ${arg}"
            ;;
    esac
done

# Strip leading space and split into positional array (bash 3.x compatible)
set -- $POSITIONAL

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    log "ERROR: Usage: cc-worktree.sh [--dry-run] <project-name> <branch-name> [base-branch]"
    exit 1
fi

PROJECT_NAME="$1"
BRANCH_NAME="$2"
BASE_BRANCH="${3:-main}"

# ── Resolve project path ───────────────────────────────────────────────────────
# Walk ~/docs_gh/ up to SEARCH_MAXDEPTH levels looking for a git repo root
# whose basename matches PROJECT_NAME.
# We use `find` with -maxdepth and check for .git to identify repo roots.

PROJECT_PATH=""
while IFS= read -r candidate; do
    if [ "$(basename "$candidate")" = "$PROJECT_NAME" ]; then
        PROJECT_PATH="$candidate"
        break
    fi
done < <(find "$DOCS_BASE" -maxdepth "$SEARCH_MAXDEPTH" -name ".git" -type d 2>/dev/null | sed 's|/.git$||')

if [ -z "$PROJECT_PATH" ]; then
    log "ERROR: Project '${PROJECT_NAME}' not found under ${DOCS_BASE} (maxdepth=${SEARCH_MAXDEPTH})"
    exit 2
fi

log "INFO: Resolved project '${PROJECT_NAME}' to ${PROJECT_PATH}"

# ── Check branch does not already exist ───────────────────────────────────────
if git -C "$PROJECT_PATH" rev-parse --verify "refs/heads/${BRANCH_NAME}" > /dev/null 2>&1; then
    log "ERROR: Branch '${BRANCH_NAME}' already exists in ${PROJECT_PATH}"
    exit 4
fi

# ── Compute worktree path ──────────────────────────────────────────────────────
WORKTREE_PATH="${WORKTREES_BASE}/${PROJECT_NAME}/${BRANCH_NAME}"

# ── Check worktree path does not already exist ────────────────────────────────
if [ -e "$WORKTREE_PATH" ]; then
    log "ERROR: Worktree path already exists: ${WORKTREE_PATH}"
    exit 3
fi

# ── Print or execute ───────────────────────────────────────────────────────────
run_cmd() {
    if [ "$DRY_RUN" = "1" ]; then
        printf '[dry-run] %s\n' "$*"
    else
        log "RUN: $*"
        "$@"
    fi
}

log "INFO: Creating worktree at ${WORKTREE_PATH} (branch=${BRANCH_NAME}, base=${BASE_BRANCH})"

run_cmd mkdir -p "$(dirname "$WORKTREE_PATH")"
run_cmd git -C "$PROJECT_PATH" worktree add -b "$BRANCH_NAME" "$WORKTREE_PATH" "$BASE_BRANCH"

if [ "$DRY_RUN" = "0" ]; then
    if ! [ -d "$WORKTREE_PATH" ]; then
        log "ERROR: git worktree add appeared to succeed but ${WORKTREE_PATH} does not exist"
        exit 5
    fi
    log "INFO: Worktree created at ${WORKTREE_PATH}"
fi

# ── Run default.post.sh if present ────────────────────────────────────────────
# Per nix-agent-shell-protocol: re-apply nix overlays after worktree creation.
POST_SCRIPT="${WORKTREE_PATH}/default.post.sh"
if [ -f "$POST_SCRIPT" ]; then
    log "INFO: Found default.post.sh — running overlay re-apply script"
    run_cmd bash "$POST_SCRIPT"
else
    log "INFO: No default.post.sh found in worktree (no overlays to re-apply)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
if [ "$DRY_RUN" = "1" ]; then
    printf '[dry-run] Worktree would be at: %s\n' "$WORKTREE_PATH"
    printf '[dry-run] Branch: %s  Base: %s\n' "$BRANCH_NAME" "$BASE_BRANCH"
else
    log "SUCCESS: worktree ready at ${WORKTREE_PATH}"
    printf 'Worktree ready: %s\n' "$WORKTREE_PATH"
    printf 'Branch: %s  (from %s/%s)\n' "$BRANCH_NAME" "$PROJECT_NAME" "$BASE_BRANCH"
    printf '\nNext steps:\n'
    printf '  cd %s\n' "$WORKTREE_PATH"
    printf '  claude --model sonnet   # or open in editor\n'
fi

exit 0
