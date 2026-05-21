#!/usr/bin/env bash
# agent_push_guard.sh — PreToolUse:Bash hook
#
# Blocks `git push` to main/master/release/prod when the push originates
# from a Claude worktree (path matches .claude/worktrees/, /private/tmp/, /tmp/).
#
# Rationale (llm#189): worktree-isolated agents have pushed to origin/main
# despite "do NOT push" prompts, bypassing orchestrator review. This hook
# enforces the policy at the tool-call level.
#
# Detection: BLOCK iff ALL three hold:
#   1. Command is a git push or gh repo sync
#   2. CWD or -C path is a Claude worktree
#   3. Target ref resolves to a protected branch (main/master/release/*/prod/*)
#
# Bypass: AGENT_PUSH_OK=1 git push ... (mirrors DESTRUCTIVE_CONFIRM= pattern)
#
# Self-test: CLAUDE_HOOK_SELFTEST=1 bash agent_push_guard.sh
#
# Source: llm#189

set -euo pipefail

# ─── Mode switch ────────────────────────────────────────────────────────────
# Soak end: 48h after the initial log-only commit (4f38319, 2026-05-19T17:00:09Z).
# After this timestamp the hook defaults to "block" regardless of DEFAULT_MODE.
# Explicitly set AGENT_PUSH_GUARD_MODE=log to opt back into log-only.
SOAK_END_UTC="2026-05-21T17:00:09Z"

# Compute current UTC epoch vs soak-end epoch. Use python3 for portability
# (macOS `date -d` is not available; BSD `date -j -f` differs from GNU).
_now_epoch=$(python3 -c "import time; print(int(time.time()))")
_soak_epoch=$(python3 -c "
import datetime
s = '${SOAK_END_UTC}'
dt = datetime.datetime.strptime(s, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc)
print(int(dt.timestamp()))
")

if [ "$_now_epoch" -ge "$_soak_epoch" ]; then
  # Soak period has ended — default to enforce mode.
  DEFAULT_MODE="block"
else
  DEFAULT_MODE="log"
fi

MODE="${AGENT_PUSH_GUARD_MODE:-$DEFAULT_MODE}"
# ─────────────────────────────────────────────────────────────────────────────

LOG_FILE="$HOME/.claude/logs/agent_push_blocked.log"
WOULD_BLOCK_LOG="$HOME/.claude/logs/agent_push_would_block.log"

log_blocked() {
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] BLOCKED push to protected branch: $1" >> "$LOG_FILE"
}

log_would_block() {
  mkdir -p "$(dirname "$WOULD_BLOCK_LOG")"
  echo "$(date -u +'%Y-%m-%dT%H:%M:%SZ') would-block: $1" >> "$WOULD_BLOCK_LOG"
}

log_allowed() {
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ALLOWED push (bypass): $1" >> "$LOG_FILE"
}

# ═══════════════════════════════════════════════════════════════════════════
# DETECTION FUNCTIONS (shared between self-test and normal operation)
# ═══════════════════════════════════════════════════════════════════════════

# Protected branch pattern (POSIX ERE)
PROTECTED_BRANCH_PATTERN='^(main|master|production|release/.*|prod/.*)$'

has_bypass() {
  # Returns 0 if AGENT_PUSH_OK=1 appears as a leading env-var in the command
  echo "$1" | grep -qE '(^|[[:space:]])AGENT_PUSH_OK=1([[:space:]]|$)'
}

is_push_command() {
  # Strip leading env-var assignments (KEY=value pairs before the command)
  local stripped_cmd
  stripped_cmd=$(echo "$1" | sed 's/^[[:space:]]*\([A-Z_][A-Z0-9_]*=[^[:space:]]*[[:space:]]*\)*//')
  echo "$stripped_cmd" | grep -qE \
    '(^git[[:space:]]+(push|-C[[:space:]]+[^[:space:]]+[[:space:]]+push)|^gh[[:space:]]+repo[[:space:]]+sync)'
}

extract_dash_c_path() {
  # Extract argument to -C flag: git -C /some/path push ...
  echo "$1" | grep -oE '\-C[[:space:]]+[^[:space:]]+' | head -1 | sed 's/-C[[:space:]]*//'
}

is_worktree_path() {
  local path="$1"
  # Pattern 1: Claude worktrees directory
  echo "$path" | grep -qE '\.claude/worktrees/' && return 0
  # Pattern 2: /private/tmp or /tmp (ephemeral agent scratch)
  echo "$path" | grep -qE '^(/private)?/tmp(/|$)' && return 0
  return 1
}

extract_target_branch() {
  local cmd="$1"
  local effective_path="$2"
  # Case A: explicit HEAD:branch refspec — git push origin HEAD:main
  local head_ref
  head_ref=$(echo "$cmd" | grep -oE 'HEAD:[^[:space:]]+' | cut -d: -f2 || echo "")
  if [ -n "$head_ref" ]; then
    echo "$head_ref"
    return
  fi
  # Case B: explicit branch refspec — git push origin main OR git push origin feat/foo
  # Strip everything up to and including 'push', then get words that don't start with -
  local after_push
  after_push=$(echo "$cmd" | sed 's/.*push[[:space:]]*//')
  local refspec
  refspec=$(echo "$after_push" | awk '{print $2}')
  if [ -n "$refspec" ]; then
    # Could be branch:branch — take destination side
    if echo "$refspec" | grep -q ':'; then
      echo "$refspec" | cut -d: -f2
    else
      echo "$refspec"
    fi
    return
  fi
  # Case C: no refspec — target is current branch (from git if path accessible)
  if [ -n "$effective_path" ] && [ -d "$effective_path" ]; then
    git -C "$effective_path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo ""
  fi
}

# Core decision function: returns "block" or "allow" with reason
# Args: cmd, cwd
decide() {
  local cmd="$1"
  local cwd="$2"

  # Bypass check
  if has_bypass "$cmd"; then
    echo "allow:bypass"
    return
  fi

  # Condition 1: push command?
  if ! is_push_command "$cmd"; then
    echo "allow:not-push"
    return
  fi

  # Condition 2: worktree path?
  local dash_c_path effective_path
  dash_c_path=$(extract_dash_c_path "$cmd")
  if [ -n "$dash_c_path" ]; then
    effective_path="$dash_c_path"
  elif [ -n "$cwd" ]; then
    effective_path="$cwd"
  else
    effective_path="${PWD:-}"
  fi

  if ! is_worktree_path "$effective_path"; then
    echo "allow:not-worktree:$effective_path"
    return
  fi

  # Condition 3: protected branch?
  local target_branch
  target_branch=$(extract_target_branch "$cmd" "$effective_path")

  if [ -z "$target_branch" ]; then
    echo "allow:no-target-detected"
    return
  fi

  if ! echo "$target_branch" | grep -qE "$PROTECTED_BRANCH_PATTERN"; then
    echo "allow:feature-branch:$target_branch"
    return
  fi

  echo "block:$target_branch:$effective_path"
}

# ═══════════════════════════════════════════════════════════════════════════
# SELF-TEST MODE
# ═══════════════════════════════════════════════════════════════════════════

if [ "${CLAUDE_HOOK_SELFTEST:-}" = "1" ]; then
  PASS=0
  FAIL=0
  TOTAL=8

  # Temp log paths to avoid polluting production logs during self-test
  SELFTEST_LOG="/tmp/agent_push_selftest_blocked_$$"
  SELFTEST_WOULD_LOG="/tmp/agent_push_selftest_would_$$"
  LOG_FILE="$SELFTEST_LOG"
  WOULD_BLOCK_LOG="$SELFTEST_WOULD_LOG"

  check_scenario() {
    local n="$1"
    local expected="$2"  # "allow" or "block"
    local cmd="$3"
    local cwd="$4"
    local result
    result=$(decide "$cmd" "$cwd")
    local actual
    actual=$(echo "$result" | cut -d: -f1)
    if [ "$actual" = "$expected" ]; then
      echo "$n/$TOTAL PASS  ($result)"
      PASS=$((PASS + 1))
    else
      echo "$n/$TOTAL FAIL  expected=$expected got=$result"
      FAIL=$((FAIL + 1))
    fi
  }

  # effective_action: applies mode logic on top of decide() — returns "allow" or "block"
  effective_action() {
    local cmd="$1"
    local cwd="$2"
    local mode="$3"
    local decision
    decision=$(decide "$cmd" "$cwd")
    local action
    action=$(echo "$decision" | cut -d: -f1)
    if [ "$action" = "block" ] && [ "$mode" = "log" ]; then
      echo "allow"
    else
      echo "$action"
    fi
  }

  check_mode_scenario() {
    local n="$1"
    local expected="$2"  # "allow" or "block"
    local cmd="$3"
    local cwd="$4"
    local mode="$5"
    local actual
    actual=$(effective_action "$cmd" "$cwd" "$mode")
    if [ "$actual" = "$expected" ]; then
      echo "$n/$TOTAL PASS  (mode=$mode, effective=$actual)"
      PASS=$((PASS + 1))
    else
      echo "$n/$TOTAL FAIL  expected=$expected got=$actual (mode=$mode)"
      FAIL=$((FAIL + 1))
    fi
  }

  # 1: push to main from main checkout → ALLOW
  check_scenario 1 "allow" \
    "git push origin main" \
    "/Users/johngavin/docs_gh/llm"

  # 2: push to main from worktree → BLOCK
  check_scenario 2 "block" \
    "git push origin main" \
    "/Users/johngavin/docs_gh/llm/.claude/worktrees/agent-abc123"

  # 3: push to feature branch from worktree → ALLOW
  check_scenario 3 "allow" \
    "git push origin feat/foo" \
    "/Users/johngavin/docs_gh/llm/.claude/worktrees/agent-abc123"

  # 4: git -C /tmp/scratch push origin main from anywhere → BLOCK
  check_scenario 4 "block" \
    "git -C /tmp/scratch push origin main" \
    "/Users/johngavin/docs_gh/llm"

  # 5: AGENT_PUSH_OK=1 git push origin main from worktree → ALLOW
  check_scenario 5 "allow" \
    "AGENT_PUSH_OK=1 git push origin main" \
    "/Users/johngavin/docs_gh/llm/.claude/worktrees/agent-abc123"

  # 6: git push origin HEAD:main from worktree → BLOCK
  check_scenario 6 "block" \
    "git push origin HEAD:main" \
    "/Users/johngavin/docs_gh/llm/.claude/worktrees/agent-abc123"

  # 7: default log-only mode + push to main from worktree → ALLOW (would-block, logged)
  check_mode_scenario 7 "allow" \
    "git push origin main" \
    "/Users/johngavin/docs_gh/llm/.claude/worktrees/agent-abc123" \
    "log"

  # 8: AGENT_PUSH_GUARD_MODE=block + push to main from worktree → BLOCK (enforce mode)
  check_mode_scenario 8 "block" \
    "git push origin main" \
    "/Users/johngavin/docs_gh/llm/.claude/worktrees/agent-abc123" \
    "block"

  # Cleanup temp test logs
  rm -f "$SELFTEST_LOG" "$SELFTEST_WOULD_LOG"

  echo ""
  echo "$PASS/$TOTAL PASS"
  [ "$FAIL" -eq 0 ] && exit 0 || exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════
# NORMAL HOOK OPERATION
# ═══════════════════════════════════════════════════════════════════════════

# Read tool input JSON from stdin (Claude's hook interface)
INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || echo "")

# Fallback: check environment variable (older hook interface)
if [ -z "$COMMAND" ]; then
  COMMAND="${CLAUDE_TOOL_INPUT:-}"
fi

# If can't parse command, allow (conservative: don't block what we can't read)
if [ -z "$COMMAND" ]; then
  exit 0
fi

DECISION=$(decide "$COMMAND" "$CWD")
ACTION=$(echo "$DECISION" | cut -d: -f1)

if [ "$ACTION" = "allow" ]; then
  # Log bypass if AGENT_PUSH_OK was set
  REASON=$(echo "$DECISION" | cut -d: -f2)
  if [ "$REASON" = "bypass" ]; then
    log_allowed "$COMMAND"
  fi
  exit 0
fi

# BLOCK path
TARGET_BRANCH=$(echo "$DECISION" | cut -d: -f2)
EFFECTIVE_PATH=$(echo "$DECISION" | cut -d: -f3)

DISPLAY_CMD="${COMMAND:0:80}"
[ ${#COMMAND} -gt 80 ] && DISPLAY_CMD="${DISPLAY_CMD}..."

# Log-only mode: record what WOULD have been blocked, then allow through
if [ "$MODE" = "log" ]; then
  log_would_block "cmd=${DISPLAY_CMD} cwd=${EFFECTIVE_PATH} target-ref=${TARGET_BRANCH}"
  cat >&2 <<EOF

[agent_push_guard] LOG-ONLY MODE: would-block push to '${TARGET_BRANCH}' from '${EFFECTIVE_PATH}'.
Recorded to $WOULD_BLOCK_LOG — switch AGENT_PUSH_GUARD_MODE=block to enforce.
Rule: agent-no-push-to-main.md | Issue: llm#189 (48h soak, PR #197)

EOF
  exit 0
fi

# Enforce mode: block the push
cat >&2 <<EOF

╔═════════════════════════════════════════════════════════════════════════════╗
║  BLOCKED — Agent worktree push to protected branch                          ║
╠═════════════════════════════════════════════════════════════════════════════╣
║                                                                             ║
║  Command:  $DISPLAY_CMD
║  Path:     $EFFECTIVE_PATH
║  Target:   $TARGET_BRANCH
║                                                                             ║
║  Worktree-isolated agents MUST NOT push to protected branches directly.     ║
║  The orchestrator reviews diffs and pushes from the main checkout.          ║
║                                                                             ║
║  Correct workflow:                                                           ║
║    1. Commit to your feature branch inside the worktree                     ║
║    2. Push to the feature branch (e.g. git push origin feat/your-branch)   ║
║    3. Open a PR — let the orchestrator or user merge                        ║
║                                                                             ║
║  To bypass (orchestrator/user only):                                        ║
║    AGENT_PUSH_OK=1 git push origin <branch>                                 ║
║                                                                             ║
║  Rule: agent-no-push-to-main.md  |  Issue: llm#189                         ║
╚═════════════════════════════════════════════════════════════════════════════╝

EOF

log_blocked "$COMMAND (path=$EFFECTIVE_PATH, target=$TARGET_BRANCH)"

exit 2
