#!/usr/bin/env bash
# destructive_fs_guard.sh — PreToolUse:Bash hook
#
# Enforces confirmation for destructive filesystem commands on protected paths.
# Uses a 4-digit code that user must type to prove they read the warning.
#
# Flow:
#   1. Direct `rm -rf` blocked by deny list in settings.json
#   2. `DESTRUCTIVE_CONFIRM=XXXX rm -rf ...` goes through this hook
#   3. Hook validates code matches expected value
#   4. If match: allow. If no match: block with instructions.
#
# Protected paths: .claude/, R/, packages/, data/, *.nix, _targets*, etc.

set -euo pipefail

# In selftest mode, skip stdin reading — functions are defined below, selftest runs after them
if [ "${CLAUDE_HOOK_SELFTEST:-0}" != "1" ]; then
  # Get the command from Claude's tool input
  # Claude passes tool input as JSON to stdin for hooks
  INPUT=$(cat)
  COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")

  # Fallback: check environment variable (older hook interface)
  if [ -z "$COMMAND" ]; then
    COMMAND="${CLAUDE_TOOL_INPUT:-}"
  fi

  # If still empty, allow (can't parse command)
  if [ -z "$COMMAND" ]; then
    exit 0
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════

# Protected paths (extended regex) — NEVER delete without confirmation
PROTECTED_PATHS='(\.claude/|\.claude$|^R/|/R/|^packages/|/packages/|^data/|/data/|inst/extdata|\.nix$|flake\.|DESCRIPTION$|NAMESPACE$|_targets|knowledge/|wiki/|raw/|\.git/|\.github/|CLAUDE\.md|CHANGELOG\.md|README)'

# Destructive command patterns (use POSIX [[:space:]] not \s for portability)
DESTRUCTIVE_PATTERNS='(rm[[:space:]]+-[rRfF]+|git[[:space:]]+clean[[:space:]]+-[fdxX]+|git[[:space:]]+reset[[:space:]]+--hard|git[[:space:]]+(checkout|restore)[[:space:]]+--?[[:space:]]*\.)'

# ═══════════════════════════════════════════════════════════════════════════
# DETECTION FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════

is_destructive() {
  echo "$1" | grep -qE "$DESTRUCTIVE_PATTERNS"
}

targets_protected() {
  echo "$1" | grep -qE "$PROTECTED_PATHS"
}

extract_confirm_code() {
  # Extract DESTRUCTIVE_CONFIRM=XXXX from command
  echo "$1" | grep -oE 'DESTRUCTIVE_CONFIRM=[0-9]{4}' | cut -d= -f2 || echo ""
}

generate_expected_code() {
  # Deterministic code from command (minus the DESTRUCTIVE_CONFIRM part)
  local clean_cmd=$(echo "$1" | sed 's/DESTRUCTIVE_CONFIRM=[0-9]* *//')
  # Use first 4 digits from md5 hash (md5sum for Linux/nix, md5 -q for macOS)
  local hash
  if command -v md5sum >/dev/null 2>&1; then
    hash=$(echo "$clean_cmd" | md5sum | cut -d' ' -f1)
  elif command -v md5 >/dev/null 2>&1; then
    hash=$(echo "$clean_cmd" | md5 -q)
  else
    hash=$(echo "$clean_cmd" | shasum -a 256 | cut -d' ' -f1)
  fi
  echo "$hash" | grep -oE '[0-9]' | head -4 | tr -d '\n'
}

strip_heredoc_bodies() {
  # Remove heredoc body content before destructive pattern matching (#617).
  # Prevents false positives when a command writes a script file that happens
  # to contain rm/git commands inside the heredoc body.
  printf '%s\n' "$1" | awk '
    /<</ {
      line = $0
      after = $0; sub(/.*<<[-]?[ \t]*/, "", after)
      gsub(/^'"'"'|^"/, "", after)
      split(after, a, /[ \t'"'"'"]/)
      delim = a[1]
      if (length(delim) > 0) {
        in_here = 1
        sub(/[ \t]*<<.*$/, "", line)
        print line
        next
      }
    }
    in_here {
      stripped = $0; sub(/^[ \t]+/, "", stripped)
      if (stripped == delim || $0 == delim) { in_here = 0 }
      next
    }
    { print }
  '
}

is_own_worktree_path() {
  # Agent harness worktrees (.claude/worktrees/agent-*) are sandboxed by
  # isolation:"worktree" and should not be blocked by PROTECTED_PATHS (#617).
  echo "$1" | grep -qE '\.claude/worktrees/agent-[a-f0-9]+'
}

# ═══════════════════════════════════════════════════════════════════════════
# SELF-TEST (CLAUDE_HOOK_SELFTEST=1)
# ═══════════════════════════════════════════════════════════════════════════

if [ "${CLAUDE_HOOK_SELFTEST:-0}" = "1" ]; then
  PASS=0; FAIL=0
  assert_destructive() {
    local desc="$1" cmd="$2"
    local surface; surface=$(strip_heredoc_bodies "$cmd")
    if is_destructive "$surface" && targets_protected "$cmd" && ! is_own_worktree_path "$cmd"; then
      PASS=$((PASS+1)); echo "PASS: $desc"
    else
      FAIL=$((FAIL+1)); echo "FAIL: $desc"
    fi
  }
  assert_allowed() {
    local desc="$1" cmd="$2"
    local surface; surface=$(strip_heredoc_bodies "$cmd")
    local would_block=0
    is_destructive "$surface" && targets_protected "$cmd" && ! is_own_worktree_path "$cmd" && would_block=1
    if [ "$would_block" -eq 0 ]; then
      PASS=$((PASS+1)); echo "PASS: $desc"
    else
      FAIL=$((FAIL+1)); echo "FAIL: $desc"
    fi
  }

  # Should BLOCK
  assert_destructive "rm -rf .claude/rules/" "rm -rf .claude/rules/"
  assert_destructive "git reset --hard with .claude/ arg" "git reset --hard .claude/scripts/"
  assert_destructive "git clean -fdx on _targets/" "git clean -fdx _targets/"

  # Should ALLOW — heredoc body with rm inside (#617 fix 1)
  assert_allowed "heredoc with rm inside body" "$(printf '%s\n' \
    "cat > /tmp/foo.sh << 'SCRIPT'" \
    "rm -rf \"\$tmp\"" \
    "SCRIPT")"
  assert_allowed "heredoc writing to .claude/scripts/ with rm body" "$(printf '%s\n' \
    "cat > .claude/scripts/foo.sh << 'EOF'" \
    "#!/bin/bash" \
    "rm -rf \"\$build_dir\"" \
    "EOF")"

  # Should ALLOW — agent harness worktree path (#617 fix 2)
  assert_allowed "rm in own harness worktree" \
    "rm -rf .claude/worktrees/agent-abc1234567890abc/"

  echo "$((PASS+FAIL)) tests: $PASS PASS, $FAIL FAIL"
  exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
fi

# ═══════════════════════════════════════════════════════════════════════════
# MAIN LOGIC
# ═══════════════════════════════════════════════════════════════════════════

# Check if command is destructive AND targets protected path.
# Strip heredoc bodies first so script content doesn't trigger the check (#617).
COMMAND_SURFACE=$(strip_heredoc_bodies "$COMMAND")
if is_destructive "$COMMAND_SURFACE" && targets_protected "$COMMAND"; then
  # Exempt agent harness worktrees — they are already sandboxed (#617).
  if is_own_worktree_path "$COMMAND"; then
    exit 0
  fi

  # Extract any provided confirmation code
  PROVIDED_CODE=$(extract_confirm_code "$COMMAND")
  EXPECTED_CODE=$(generate_expected_code "$COMMAND")

  # Ensure we have a 4-digit code (pad with zeros if needed)
  if [ ${#EXPECTED_CODE} -lt 4 ]; then
    EXPECTED_CODE=$(printf "%04d" "$((RANDOM % 10000))")
  fi
  EXPECTED_CODE=${EXPECTED_CODE:0:4}

  if [ "$PROVIDED_CODE" = "$EXPECTED_CODE" ]; then
    # Code matches — allow execution
    # Log the confirmed destructive command
    LOG_FILE="$HOME/.claude/logs/destructive_confirmed.log"
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] CONFIRMED: $COMMAND" >> "$LOG_FILE"
    exit 0
  fi

  # No code or wrong code — block with instructions
  # Truncate command for display
  DISPLAY_CMD="${COMMAND:0:70}"
  [ ${#COMMAND} -gt 70 ] && DISPLAY_CMD="${DISPLAY_CMD}..."

  cat >&2 <<EOF

╔════════════════════════════════════════════════════════════════════════════╗
║  ⛔ DESTRUCTIVE COMMAND BLOCKED — Protected Path Detected                  ║
╠════════════════════════════════════════════════════════════════════════════╣
║                                                                            ║
║  Command: $DISPLAY_CMD
║                                                                            ║
║  This command would modify or delete a PROTECTED path:                     ║
║    .claude/, R/, packages/, data/, *.nix, _targets, knowledge/, etc.       ║
║                                                                            ║
║  ┌──────────────────────────────────────────────────────────────────────┐  ║
║  │  To proceed, ask the user to confirm by saying:                      │  ║
║  │                                                                      │  ║
║  │    "proceed with code $EXPECTED_CODE"                                      │  ║
║  │                                                                      │  ║
║  │  Then re-run as:                                                     │  ║
║  │    DESTRUCTIVE_CONFIRM=$EXPECTED_CODE <command>                            │  ║
║  └──────────────────────────────────────────────────────────────────────┘  ║
║                                                                            ║
║  This requires the USER to type the code, proving they read this warning.  ║
║  The code is specific to this exact command.                               ║
║                                                                            ║
╚════════════════════════════════════════════════════════════════════════════╝

EOF

  # Log the blocked attempt
  LOG_FILE="$HOME/.claude/logs/destructive_blocked.log"
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] BLOCKED (code: $EXPECTED_CODE): $COMMAND" >> "$LOG_FILE"

  exit 1
fi

# Not a destructive command on protected path — allow
exit 0
