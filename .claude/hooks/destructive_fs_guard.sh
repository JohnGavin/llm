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

# ═══════════════════════════════════════════════════════════════════════════
# MAIN LOGIC
# ═══════════════════════════════════════════════════════════════════════════

# Check if command is destructive AND targets protected path
if is_destructive "$COMMAND" && targets_protected "$COMMAND"; then

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
