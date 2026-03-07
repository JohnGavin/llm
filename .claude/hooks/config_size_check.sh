#!/usr/bin/env bash
# config_size_check.sh - Audit line counts of Claude config files
# Runs at SessionStart and via /hi command.

set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
# Find memory dir for the current project (if available)
MEMORY_DIR=""
for d in "$CLAUDE_DIR"/projects/*/memory; do
  [ -d "$d" ] && MEMORY_DIR="$d" && break
done

echo "Config Size Audit"
echo "================="

check_file() {
  local file="$1" warn_threshold="$2" fail_threshold="$3" label="$4"
  if [ ! -f "$file" ]; then
    echo "$label: MISSING"
    return
  fi
  local lines
  lines=$(timeout 5 wc -l < "$file" 2>/dev/null || echo "TIMEOUT")
  if [ "$lines" = "TIMEOUT" ]; then
    echo "$label: TIMEOUT reading file"
    return
  fi
  if [ "$lines" -gt "$fail_threshold" ]; then
    echo "$label: $lines lines  FAIL (>${fail_threshold})"
  elif [ "$lines" -gt "$warn_threshold" ]; then
    echo "$label: $lines lines  WARN (>${warn_threshold})"
  else
    echo "$label: $lines lines  OK"
  fi
}

# CLAUDE.md
check_file "$CLAUDE_DIR/CLAUDE.md" 200 500 "CLAUDE.md"

# MEMORY.md
if [ -n "$MEMORY_DIR" ] && [ -f "$MEMORY_DIR/MEMORY.md" ]; then
  check_file "$MEMORY_DIR/MEMORY.md" 150 200 "MEMORY.md"
else
  echo "MEMORY.md: NOT FOUND (no memory directory)"
fi

# Rules
rules_dir="$CLAUDE_DIR/rules"
if [ -d "$rules_dir" ]; then
  n_rules=0 max_lines=0 max_file="" total_lines=0 n_warn=0
  for f in "$rules_dir"/*.md; do
    [ -f "$f" ] || continue
    lines=$(timeout 5 wc -l < "$f" 2>/dev/null || echo 0)
    n_rules=$((n_rules + 1))
    total_lines=$((total_lines + lines))
    if [ "$lines" -gt "$max_lines" ]; then
      max_lines=$lines
      max_file=$(basename "$f")
    fi
    [ "$lines" -gt 150 ] && n_warn=$((n_warn + 1))
  done
  if [ "$n_rules" -gt 0 ]; then
    avg=$((total_lines / n_rules))
    msg="Rules ($n_rules):  avg $avg, max $max_lines ($max_file)"
    [ "$n_warn" -gt 0 ] && msg="$msg  WARN: $n_warn files >150"
    echo "$msg"
  fi
fi

# Skills
skills_dir="$CLAUDE_DIR/skills"
if [ -d "$skills_dir" ]; then
  n_skills=0 max_lines=0 max_file="" total_lines=0 n_warn=0
  while IFS= read -r -d '' f; do
    lines=$(timeout 5 wc -l < "$f" 2>/dev/null || echo 0)
    n_skills=$((n_skills + 1))
    total_lines=$((total_lines + lines))
    parent=$(basename "$(dirname "$f")")
    if [ "$lines" -gt "$max_lines" ]; then
      max_lines=$lines
      max_file="$parent"
    fi
    [ "$lines" -gt 500 ] && n_warn=$((n_warn + 1))
  done < <(find -L "$skills_dir" -name "SKILL.md" -print0 2>/dev/null)
  # Also count top-level .md files
  for f in "$skills_dir"/*.md; do
    [ -f "$f" ] || continue
    bname=$(basename "$f" .md)
    case "$bname" in README|SKILLS_UPDATE*) continue ;; esac
    lines=$(timeout 5 wc -l < "$f" 2>/dev/null || echo 0)
    n_skills=$((n_skills + 1))
    total_lines=$((total_lines + lines))
    if [ "$lines" -gt "$max_lines" ]; then
      max_lines=$lines
      max_file="$bname"
    fi
    [ "$lines" -gt 500 ] && n_warn=$((n_warn + 1))
  done
  if [ "$n_skills" -gt 0 ]; then
    avg=$((total_lines / n_skills))
    msg="Skills ($n_skills): avg $avg, max $max_lines ($max_file)"
    [ "$n_warn" -gt 0 ] && msg="$msg  WARN: $n_warn files >500"
    echo "$msg"
  fi
fi

# Agents
agents_dir="$CLAUDE_DIR/agents"
if [ -d "$agents_dir" ]; then
  n_agents=0 max_lines=0 total_lines=0
  for f in "$agents_dir"/*.md; do
    [ -f "$f" ] || continue
    lines=$(timeout 5 wc -l < "$f" 2>/dev/null || echo 0)
    n_agents=$((n_agents + 1))
    total_lines=$((total_lines + lines))
    [ "$lines" -gt "$max_lines" ] && max_lines=$lines
  done
  if [ "$n_agents" -gt 0 ]; then
    avg=$((total_lines / n_agents))
    echo "Agents ($n_agents):  avg $avg, max $max_lines  OK"
  fi
fi

# Commands
commands_dir="$CLAUDE_DIR/commands"
if [ -d "$commands_dir" ]; then
  n_cmds=0 max_lines=0 total_lines=0
  for f in "$commands_dir"/*.md; do
    [ -f "$f" ] || continue
    lines=$(timeout 5 wc -l < "$f" 2>/dev/null || echo 0)
    n_cmds=$((n_cmds + 1))
    total_lines=$((total_lines + lines))
    [ "$lines" -gt "$max_lines" ] && max_lines=$lines
  done
  if [ "$n_cmds" -gt 0 ]; then
    avg=$((total_lines / n_cmds))
    echo "Commands ($n_cmds): avg $avg, max $max_lines  OK"
  fi
fi

exit 0
