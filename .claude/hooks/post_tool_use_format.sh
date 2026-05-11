#!/usr/bin/env bash
# PostToolUse hook: Auto-format R files and check dark mode contrast for Quarto
#
# Triggered after: Edit, Write tools
# Auto-runs: styler::style_file() for .R files, check_dark_contrast.sh for .qmd
#
# See: Stephen Turner "Underutilized Claude Code Features"
# Related: dark-mode-completeness rule, tidyverse-style skill

set -e

LOG="$HOME/.claude/logs/post_tool_use_format.log"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

# Only process Edit and Write tool calls
[[ "$TOOL_NAME" != "Edit" && "$TOOL_NAME" != "Write" ]] && exit 0

# Extract file path from tool call
FILE_PATH="$FILE_PATH"  # Set by Claude Code
[[ -z "$FILE_PATH" ]] && exit 0
[[ ! -f "$FILE_PATH" ]] && exit 0

log "PostToolUse: $TOOL_NAME on $FILE_PATH"

# Auto-format R files with styler
if [[ "$FILE_PATH" =~ \.R$ ]]; then
  log "Running styler on $FILE_PATH"

  # Run in background to avoid blocking tool response
  (
    timeout 30 Rscript -e "styler::style_file('$FILE_PATH')" >> "$LOG" 2>&1
    if [[ $? -eq 0 ]]; then
      log "✓ Styled: $FILE_PATH"
    else
      log "✗ Styler failed on $FILE_PATH"
    fi
  ) &
fi

# Check dark mode contrast for Quarto files
if [[ "$FILE_PATH" =~ \.qmd$ ]]; then
  log "Checking dark mode contrast for $FILE_PATH"

  # Run in background
  (
    CONTRAST_SCRIPT="$HOME/docs_gh/llm/.claude/scripts/check_dark_contrast.sh"
    if [[ -x "$CONTRAST_SCRIPT" ]]; then
      "$CONTRAST_SCRIPT" "$FILE_PATH" >> "$LOG" 2>&1
      if [[ $? -eq 0 ]]; then
        log "✓ Dark mode contrast OK: $FILE_PATH"
      else
        log "⚠ Dark mode contrast issues in $FILE_PATH"
      fi
    fi
  ) &
fi

exit 0
