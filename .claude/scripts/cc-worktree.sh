#!/usr/bin/env bash
# cc-worktree.sh — Create a git worktree at ~/docs_gh/worktrees/<project>/<branch>/
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
# Convention (worktree-location rule, llm#582):
#   All worktrees go under ~/docs_gh/worktrees/<project>/<branch>/
#   (legacy location ~/worktrees/ is read-only transitional — no new
#   worktrees are created there)
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
WORKTREES_BASE="$HOME/docs_gh/worktrees"
DOCS_BASE="$HOME/docs_gh"
SEARCH_MAXDEPTH=3
PROJECTS_CONF="${HOME}/.config/cc-worktree/projects.conf"

# ── Logging ────────────────────────────────────────────────────────────────────
log() {
    mkdir -p "$LOG_DIR"
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
    printf '%s\n' "$*" >&2
}

# ── Parse arguments ────────────────────────────────────────────────────────────
DRY_RUN=0
VALIDATE_CONFIG=0
POSITIONAL=""

for arg in "$@"; do
    case "$arg" in
        --dry-run)
            DRY_RUN=1
            ;;
        --validate-config)
            VALIDATE_CONFIG=1
            ;;
        *)
            POSITIONAL="${POSITIONAL} ${arg}"
            ;;
    esac
done

# ── --validate-config short-circuit ────────────────────────────────────────────
# Reads the projects.conf, checks each entry's path exists and is a git repo.
# Used by humans + the worktree-location rule's quarterly review to catch
# entries that have rotted after a project move. See JohnGavin/llm#424.
if [ "$VALIDATE_CONFIG" = "1" ]; then
    if [ ! -r "$PROJECTS_CONF" ]; then
        printf 'No config at %s — skipping (the filesystem search fallback still works)\n' "$PROJECTS_CONF"
        exit 0
    fi
    EXIT_CODE=0
    while IFS='=' read -r CONF_NAME CONF_PATH; do
        # Skip comments and blank lines
        case "$CONF_NAME" in
            ''|\#*) continue ;;
        esac
        # Trim whitespace
        CONF_NAME="${CONF_NAME## }"; CONF_NAME="${CONF_NAME%% }"
        CONF_PATH="${CONF_PATH## }"; CONF_PATH="${CONF_PATH%% }"
        # Strip one layer of surrounding quotes (handles KEY="value" style env files)
        CONF_PATH="${CONF_PATH#\"}"; CONF_PATH="${CONF_PATH%\"}"
        CONF_PATH="${CONF_PATH#\'}"; CONF_PATH="${CONF_PATH%\'}"
        if [ -d "$CONF_PATH/.git" ] || [ -f "$CONF_PATH/.git" ]; then
            printf 'OK     %-25s %s\n' "$CONF_NAME" "$CONF_PATH"
        else
            printf 'FAIL   %-25s %s (no .git found)\n' "$CONF_NAME" "$CONF_PATH"
            EXIT_CODE=1
        fi
    done < "$PROJECTS_CONF"
    exit "$EXIT_CODE"
fi

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
# Two-tier lookup (see JohnGavin/llm#424):
# 1. Canonical config at ~/.config/cc-worktree/projects.conf maps name→path.
#    Format: <name>=<absolute-path>; lines starting with # are comments.
# 2. If no config OR project not in config, fall back to filesystem search.
#    On AMBIGUOUS filesystem match (multiple repos with the same basename),
#    refuse to guess — exit with the candidate list and instruct the user to
#    add the canonical path to the config.

PROJECT_PATH=""

# Tier 1: config
if [ -r "$PROJECTS_CONF" ]; then
    while IFS='=' read -r CONF_NAME CONF_PATH; do
        case "$CONF_NAME" in
            ''|\#*) continue ;;
        esac
        CONF_NAME="${CONF_NAME## }"; CONF_NAME="${CONF_NAME%% }"
        CONF_PATH="${CONF_PATH## }"; CONF_PATH="${CONF_PATH%% }"
        # Strip one layer of surrounding quotes (handles KEY="value" style env files)
        CONF_PATH="${CONF_PATH#\"}"; CONF_PATH="${CONF_PATH%\"}"
        CONF_PATH="${CONF_PATH#\'}"; CONF_PATH="${CONF_PATH%\'}"
        if [ "$CONF_NAME" = "$PROJECT_NAME" ]; then
            if [ -d "$CONF_PATH/.git" ] || [ -f "$CONF_PATH/.git" ]; then
                PROJECT_PATH="$CONF_PATH"
                log "INFO: Resolved '${PROJECT_NAME}' to ${PROJECT_PATH} via ${PROJECTS_CONF}"
            else
                log "WARN: ${PROJECTS_CONF} maps ${PROJECT_NAME} -> ${CONF_PATH} but no .git there — falling back to filesystem search"
            fi
            break
        fi
    done < "$PROJECTS_CONF"
fi

# Tier 2: filesystem search (with ambiguity guard)
if [ -z "$PROJECT_PATH" ]; then
    MATCHES=""
    MATCH_COUNT=0
    while IFS= read -r candidate; do
        if [ "$(basename "$candidate")" = "$PROJECT_NAME" ]; then
            MATCHES="${MATCHES}${candidate}"$'\n'
            MATCH_COUNT=$(( MATCH_COUNT + 1 ))
        fi
    done < <(find "$DOCS_BASE" -maxdepth "$SEARCH_MAXDEPTH" -name ".git" 2>/dev/null | sed 's|/.git$||')

    if [ "$MATCH_COUNT" = "0" ]; then
        log "ERROR: Project '${PROJECT_NAME}' not found under ${DOCS_BASE} (maxdepth=${SEARCH_MAXDEPTH})"
        log "       If the project is at a non-conventional path, add it to ${PROJECTS_CONF}:"
        log "         ${PROJECT_NAME}=/absolute/path/to/repo"
        exit 2
    fi

    if [ "$MATCH_COUNT" -gt 1 ]; then
        log "ERROR: Project '${PROJECT_NAME}' has multiple candidates — refusing to guess (JohnGavin/llm#424):"
        printf '%s' "$MATCHES" | while IFS= read -r m; do
            [ -n "$m" ] && log "       - ${m}"
        done
        log "       Add the canonical one to ${PROJECTS_CONF}:"
        log "         ${PROJECT_NAME}=/canonical/path"
        exit 2
    fi

    PROJECT_PATH=$(printf '%s' "$MATCHES" | head -n1)
    log "INFO: Resolved '${PROJECT_NAME}' to ${PROJECT_PATH} via filesystem search"
fi

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
