#!/usr/bin/env bash
# agents_md_audit.sh - Check AGENTS.md counts match actual files
# Returns compact summary: "AGENTS.md: ok" or "AGENTS.md: DRIFT ..."
set -uo pipefail

CLAUDE_DIR="$HOME/.claude"
# Find AGENTS.md in the current project or llm project
AGENTS_MD=""
for f in "AGENTS.md" "$HOME/docs_gh/llm/AGENTS.md"; do
  [ -f "$f" ] && AGENTS_MD="$f" && break
done
[ -z "$AGENTS_MD" ] && echo "AGENTS.md: not found" && exit 0

# Actual counts
actual_agents=$(ls "$CLAUDE_DIR"/agents/*.md 2>/dev/null | wc -l | tr -d ' ')
actual_skills=$(ls -d "$CLAUDE_DIR"/skills/*/ 2>/dev/null | wc -l | tr -d ' ')
actual_rules=$(ls "$CLAUDE_DIR"/rules/*.md 2>/dev/null | wc -l | tr -d ' ')
actual_commands=$(ls "$CLAUDE_DIR"/commands/*.md 2>/dev/null | wc -l | tr -d ' ')
actual_hooks=$(ls "$CLAUDE_DIR"/hooks/*.sh 2>/dev/null | wc -l | tr -d ' ')

# Memory dir (match current project via cwd)
MEMORY_DIR=""
cwd_key=$(pwd | sed 's|/|-|g; s|^-||')
for d in "$CLAUDE_DIR"/projects/*/memory; do
  [ -d "$d" ] || continue
  proj_key=$(basename "$(dirname "$d")")
  if echo "$cwd_key" | grep -q "$(echo "$proj_key" | sed 's|^-||')"; then
    MEMORY_DIR="$d"
    break
  fi
done
# Fallback: llm project memory
[ -z "$MEMORY_DIR" ] && [ -d "$CLAUDE_DIR/projects/-Users-johngavin-docs-gh-llm/memory" ] && \
  MEMORY_DIR="$CLAUDE_DIR/projects/-Users-johngavin-docs-gh-llm/memory"
actual_memory=0
[ -n "$MEMORY_DIR" ] && actual_memory=$(ls "$MEMORY_DIR"/*.md 2>/dev/null | wc -l | tr -d ' ')

# Parse AGENTS.md header counts (handles "Skills by Category (62)" etc.)
extract_count() {
  grep -E "## .*$1.*\([0-9]+" "$AGENTS_MD" | grep -oE '\([0-9]+' | grep -oE '[0-9]+' | head -1
}
claimed_agents=$(extract_count "Agents")
claimed_skills=$(extract_count "Skills")
claimed_rules=$(extract_count "Rules")
claimed_commands=$(extract_count "Commands")
claimed_memory=$(extract_count "Memory")

# Compare
drift=""
[ "${claimed_agents:-0}" != "$actual_agents" ] && drift="${drift}agents:${claimed_agents:-?}→${actual_agents} "
[ "${claimed_skills:-0}" != "$actual_skills" ] && drift="${drift}skills:${claimed_skills:-?}→${actual_skills} "
[ "${claimed_rules:-0}" != "$actual_rules" ] && drift="${drift}rules:${claimed_rules:-?}→${actual_rules} "
[ "${claimed_commands:-0}" != "$actual_commands" ] && drift="${drift}cmds:${claimed_commands:-?}→${actual_commands} "
[ "${claimed_memory:-0}" != "$actual_memory" ] && drift="${drift}mem:${claimed_memory:-?}→${actual_memory} "

if [ -n "$drift" ]; then
  echo "AGENTS.md: DRIFT $drift"
  exit 1
else
  echo "AGENTS.md: ok (${actual_agents}a ${actual_skills}s ${actual_rules}r ${actual_commands}c ${actual_memory}m)"
  exit 0
fi
