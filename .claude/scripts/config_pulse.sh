#!/usr/bin/env bash
# config_pulse.sh - Collect Claude Code global config metrics
# Writes daily Parquet snapshots to ~/.claude/logs/config/
# Tracks: rules, skills, agents, hooks, memories, CLAUDE.md size
#
# Usage:
#   config_pulse.sh                    # Snapshot global config
#
# Requires: duckdb CLI
# Schedule: daily via cron or launchd
# Related: #121 (Global Config Evolution Dashboard)

set -uo pipefail

LOG_DIR="$HOME/.claude/logs/config"
TODAY=$(date +%Y-%m-%d)
OUTFILE="$LOG_DIR/$TODAY.csv"
PARQUET="$LOG_DIR/$TODAY.parquet"
CONFIG_DIR="$HOME/.claude"

mkdir -p "$LOG_DIR"

# CSV header
echo "snapshot_date,category,item,metric,value" > "$OUTFILE"

# --- AGENTS.md metrics ---
if [ -f "$CONFIG_DIR/AGENTS.md" ]; then
  lines=$(wc -l < "$CONFIG_DIR/AGENTS.md" | tr -d ' ')
  bytes=$(wc -c < "$CONFIG_DIR/AGENTS.md" | tr -d ' ')
  # Token estimate: ~4 chars per token
  tokens=$((bytes / 4))
  echo "$TODAY,agents,AGENTS.md,lines,$lines" >> "$OUTFILE"
  echo "$TODAY,agents,AGENTS.md,bytes,$bytes" >> "$OUTFILE"
  echo "$TODAY,agents,AGENTS.md,tokens_estimate,$tokens" >> "$OUTFILE"

  # Count agent definitions (lines starting with `| `)
  n_agents=$(grep -cE '^\| `[a-z-]+`' "$CONFIG_DIR/AGENTS.md" 2>/dev/null || echo "0")
  echo "$TODAY,agents,AGENTS.md,agent_count,$n_agents" >> "$OUTFILE"
fi

# --- Global CLAUDE.md metrics ---
if [ -f "$CONFIG_DIR/CLAUDE.md" ]; then
  lines=$(wc -l < "$CONFIG_DIR/CLAUDE.md" | tr -d ' ')
  bytes=$(wc -c < "$CONFIG_DIR/CLAUDE.md" | tr -d ' ')
  tokens=$((bytes / 4))
  echo "$TODAY,claude_md,CLAUDE.md,lines,$lines" >> "$OUTFILE"
  echo "$TODAY,claude_md,CLAUDE.md,bytes,$bytes" >> "$OUTFILE"
  echo "$TODAY,claude_md,CLAUDE.md,tokens_estimate,$tokens" >> "$OUTFILE"
fi

# --- Rules metrics ---
# Note: Use -L to follow symlinks (global config uses symlinks to llm repo)
if [ -d "$CONFIG_DIR/rules" ]; then
  n_rules=$(find -L "$CONFIG_DIR/rules" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
  echo "$TODAY,rules,all,count,$n_rules" >> "$OUTFILE"

  # Total lines across all rules
  total_lines=$(find -L "$CONFIG_DIR/rules" -name "*.md" -exec cat {} + 2>/dev/null | wc -l | tr -d ' ')
  echo "$TODAY,rules,all,total_lines,$total_lines" >> "$OUTFILE"

  # Average lines per rule
  if [ "$n_rules" -gt 0 ]; then
    avg_lines=$((total_lines / n_rules))
    echo "$TODAY,rules,all,avg_lines,$avg_lines" >> "$OUTFILE"
  fi

  # Rules over 150 lines (threshold from CLAUDE.md)
  n_over_threshold=$(find -L "$CONFIG_DIR/rules" -name "*.md" -exec wc -l {} \; 2>/dev/null \
    | awk '$1 > 150 {count++} END {print count+0}')
  echo "$TODAY,rules,all,over_150_lines,$n_over_threshold" >> "$OUTFILE"

  # Per-rule line counts (top 10 largest)
  find -L "$CONFIG_DIR/rules" -name "*.md" -exec wc -l {} \; 2>/dev/null \
    | sort -rn | head -10 | while read -r lines filepath; do
      name=$(basename "$filepath" .md)
      echo "$TODAY,rules,$name,lines,$lines"
    done >> "$OUTFILE"

  # Frontmatter compliance: rules with proper YAML frontmatter
  n_with_fm=$(find -L "$CONFIG_DIR/rules" -name "*.md" -exec grep -l '^---$' {} \; 2>/dev/null | wc -l | tr -d ' ')
  echo "$TODAY,rules,all,with_frontmatter,$n_with_fm" >> "$OUTFILE"
fi

# --- Skills metrics ---
if [ -d "$CONFIG_DIR/skills" ]; then
  # Count skill directories (each skill is a directory)
  n_skills=$(find -L "$CONFIG_DIR/skills" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
  echo "$TODAY,skills,all,count,$n_skills" >> "$OUTFILE"

  # Total lines across all SKILL.md files
  total_lines=$(find -L "$CONFIG_DIR/skills" -name "SKILL.md" -exec cat {} + 2>/dev/null | wc -l | tr -d ' ')
  echo "$TODAY,skills,all,total_lines,$total_lines" >> "$OUTFILE"

  # Average skill size
  if [ "$n_skills" -gt 0 ]; then
    avg_lines=$((total_lines / n_skills))
    echo "$TODAY,skills,all,avg_lines,$avg_lines" >> "$OUTFILE"
  fi

  # Per-skill sizes (top 10 largest)
  find -L "$CONFIG_DIR/skills" -name "SKILL.md" -exec wc -l {} \; 2>/dev/null \
    | sort -rn | head -10 | while read -r lines filepath; do
      # Extract skill name from path (parent directory)
      name=$(basename "$(dirname "$filepath")")
      echo "$TODAY,skills,$name,lines,$lines"
    done >> "$OUTFILE"
fi

# --- Hooks metrics ---
if [ -d "$CONFIG_DIR/hooks" ]; then
  n_hooks=$(find -L "$CONFIG_DIR/hooks" -name "*.sh" 2>/dev/null | wc -l | tr -d ' ')
  echo "$TODAY,hooks,all,count,$n_hooks" >> "$OUTFILE"

  # Total hook lines
  total_lines=$(find -L "$CONFIG_DIR/hooks" -name "*.sh" -exec cat {} + 2>/dev/null | wc -l | tr -d ' ')
  echo "$TODAY,hooks,all,total_lines,$total_lines" >> "$OUTFILE"

  # Per-hook sizes
  find -L "$CONFIG_DIR/hooks" -name "*.sh" -exec wc -l {} \; 2>/dev/null \
    | while read -r lines filepath; do
      name=$(basename "$filepath" .sh)
      echo "$TODAY,hooks,$name,lines,$lines"
    done >> "$OUTFILE"
fi

# --- Memory metrics ---
if [ -d "$CONFIG_DIR/memory" ]; then
  n_memories=$(find -L "$CONFIG_DIR/memory" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
  echo "$TODAY,memory,all,count,$n_memories" >> "$OUTFILE"

  total_lines=$(find -L "$CONFIG_DIR/memory" -name "*.md" -exec cat {} + 2>/dev/null | wc -l | tr -d ' ')
  echo "$TODAY,memory,all,total_lines,$total_lines" >> "$OUTFILE"
fi

# --- Commands/templates metrics ---
if [ -d "$CONFIG_DIR/commands" ]; then
  n_commands=$(find -L "$CONFIG_DIR/commands" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
  echo "$TODAY,commands,all,count,$n_commands" >> "$OUTFILE"
fi

if [ -d "$CONFIG_DIR/templates" ]; then
  n_templates=$(find -L "$CONFIG_DIR/templates" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
  echo "$TODAY,templates,all,count,$n_templates" >> "$OUTFILE"
fi

# --- Scripts metrics ---
if [ -d "$CONFIG_DIR/scripts" ]; then
  n_scripts=$(find -L "$CONFIG_DIR/scripts" -name "*.sh" 2>/dev/null | wc -l | tr -d ' ')
  echo "$TODAY,scripts,all,count,$n_scripts" >> "$OUTFILE"

  total_lines=$(find -L "$CONFIG_DIR/scripts" -name "*.sh" -exec cat {} + 2>/dev/null | wc -l | tr -d ' ')
  echo "$TODAY,scripts,all,total_lines,$total_lines" >> "$OUTFILE"
fi

# --- Overall totals ---
total_md_files=$(find -L "$CONFIG_DIR" -name "*.md" -not -path "*/logs/*" 2>/dev/null | wc -l | tr -d ' ')
echo "$TODAY,total,all,md_files,$total_md_files" >> "$OUTFILE"

total_sh_files=$(find -L "$CONFIG_DIR" -name "*.sh" -not -path "*/logs/*" 2>/dev/null | wc -l | tr -d ' ')
echo "$TODAY,total,all,sh_files,$total_sh_files" >> "$OUTFILE"

# Total bytes (excluding logs)
total_bytes=$(find "$CONFIG_DIR" \( -name "*.md" -o -name "*.sh" \) -not -path "*/logs/*" -exec cat {} + 2>/dev/null | wc -c | tr -d ' ')
echo "$TODAY,total,all,bytes,$total_bytes" >> "$OUTFILE"
echo "$TODAY,total,all,tokens_estimate,$((total_bytes / 4))" >> "$OUTFILE"

# Convert CSV to Parquet via DuckDB CLI
if command -v duckdb >/dev/null 2>&1; then
  duckdb -c "COPY (SELECT * FROM read_csv('$OUTFILE', sep=',', header=true, all_varchar=true)) TO '$PARQUET' (FORMAT PARQUET);" 2>/dev/null
  if [ -f "$PARQUET" ]; then
    n_rows=$(duckdb -c "SELECT COUNT(*) FROM read_parquet('$PARQUET');" 2>/dev/null | grep -oE '[0-9]+' | tail -1)
    echo "Wrote $PARQUET ($n_rows rows)"
  else
    echo "WARNING: Parquet conversion failed, keeping CSV at $OUTFILE"
  fi
else
  echo "WARNING: duckdb CLI not found, keeping CSV at $OUTFILE"
fi
