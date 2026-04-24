#!/usr/bin/env bash
# git_project_pulse.sh - Collect git diagnostics across all active projects
# Writes daily Parquet snapshots to ~/.claude/logs/git/
# Read by llmtelemetry package for dashboard/analysis (via duckplyr, no raw SQL)
#
# Usage:
#   git_project_pulse.sh                    # All active projects
#   git_project_pulse.sh /path/to/repo      # Single project
#
# Requires: git, duckdb CLI
# Schedule: daily via cron or launchd

set -uo pipefail
# Note: -e omitted deliberately — git log | sort | head pipelines
# produce SIGPIPE (exit 141) when head closes early, which is expected.

LOG_DIR="$HOME/.claude/logs/git"
TODAY=$(date +%Y-%m-%d)
OUTFILE="$LOG_DIR/$TODAY.csv"
PARQUET="$LOG_DIR/$TODAY.parquet"

mkdir -p "$LOG_DIR"

# Active projects: repos with commits in the last 90 days
# Override with a single repo argument
if [ $# -ge 1 ]; then
  REPOS=("$1")
else
  REPOS=()
  for d in "$HOME/docs_gh"/*/; do
    [ -d "$d.git" ] || continue
    last_commit=$(git -C "$d" log -1 --format='%at' 2>/dev/null || echo "0")
    ninety_days_ago=$(date -v-90d +%s 2>/dev/null || date -d '90 days ago' +%s 2>/dev/null || echo "0")
    if [ "$last_commit" -gt "$ninety_days_ago" ]; then
      REPOS+=("$d")
    fi
  done
fi

# Gap detection: warn about missing days in the last 7 days
for i in 1 2 3 4 5 6 7; do
  gap_date=$(date -v-${i}d +%Y-%m-%d 2>/dev/null || date -d "$i days ago" +%Y-%m-%d 2>/dev/null)
  if [ -n "$gap_date" ] && [ ! -f "$LOG_DIR/$gap_date.parquet" ] && [ ! -f "$LOG_DIR/$gap_date.csv" ]; then
    echo "NOTE: No pulse data for $gap_date (laptop closed or cron missed)"
  fi
done

# CSV header
echo "snapshot_date,project,period,period_label,metric,value" > "$OUTFILE"

for repo in "${REPOS[@]}"; do
  project=$(basename "$repo")

  # --- Daily commits (last 90 days) ---
  git -C "$repo" log --format='%ad' --date=format:'%Y-%m-%d' --since="90 days ago" 2>/dev/null \
    | sort | uniq -c | while read -r count day; do
      echo "$TODAY,$project,day,$day,commits,$count"
    done >> "$OUTFILE"

  # --- Weekly commits (last 26 weeks) ---
  git -C "$repo" log --format='%ad' --date=format:'%Y-W%V' --since="26 weeks ago" 2>/dev/null \
    | sort | uniq -c | while read -r count week; do
      echo "$TODAY,$project,week,$week,commits,$count"
    done >> "$OUTFILE"

  # --- Monthly commits (all time) ---
  git -C "$repo" log --format='%ad' --date=format:'%Y-%m' 2>/dev/null \
    | sort | uniq -c | while read -r count month; do
      echo "$TODAY,$project,month,$month,commits,$count"
    done >> "$OUTFILE"

  # --- File churn (last 6 months, top 20) ---
  git -C "$repo" log --format=format: --name-only --since="6 months ago" 2>/dev/null \
    | grep -v '^$' | sort | uniq -c | sort -nr | head -20 \
    | while read -r count filepath; do
      echo "$TODAY,$project,6mo,$filepath,file_churn,$count"
    done >> "$OUTFILE"

  # --- Bug hotspots (last 6 months, top 10) ---
  git -C "$repo" log -i -E --grep="fix|bug|broken" --name-only --format='' --since="6 months ago" 2>/dev/null \
    | grep -v '^$' | sort | uniq -c | sort -nr | head -10 \
    | while read -r count filepath; do
      echo "$TODAY,$project,6mo,$filepath,bug_hotspot,$count"
    done >> "$OUTFILE"

  # --- Contributors ---
  git -C "$repo" shortlog -sn --no-merges --since="6 months ago" 2>/dev/null \
    | sed 's/^[[:space:]]*//' | while IFS=$'\t' read -r count author; do
      # Sanitise author name: strip commas to avoid CSV field corruption
      author_clean=$(echo "$author" | tr ',' ' ')
      [ -n "$count" ] && [ -n "$author_clean" ] && \
        echo "$TODAY,$project,6mo,$author_clean,contributor_commits,$count"
    done >> "$OUTFILE"

  # --- Firefighting (reverts/hotfixes, last 6 months) ---
  n_revert=$(git -C "$repo" log --oneline --since="6 months ago" 2>/dev/null \
    | grep -ciE 'revert|hotfix|emergency|rollback' || true)
  echo "$TODAY,$project,6mo,firefighting,reverts_hotfixes,${n_revert:-0}" >> "$OUTFILE"

  # --- Total commits (all time) ---
  total=$(git -C "$repo" rev-list --count HEAD 2>/dev/null || echo "0")
  echo "$TODAY,$project,all,total,total_commits,$total" >> "$OUTFILE"

  # --- Last commit date ---
  last_date=$(git -C "$repo" log -1 --format='%ad' --date=short 2>/dev/null || echo "unknown")
  echo "$TODAY,$project,all,$last_date,last_commit_date,1" >> "$OUTFILE"

  # --- Change coupling: files that change together (Tornhill, "Code as Crime Scene") ---
  # Top 10 file pairs that co-occur in commits (last 6 months)
  git -C "$repo" log --pretty="format:COMMIT" --name-only --since="6 months ago" 2>/dev/null \
    | awk '/^COMMIT$/{if(n>0)for(i in f)for(j in f)if(i<j)print i"|"j; delete f; n=0; next} /^$/{next} {f[$0]=1; n++}' \
    | sort | uniq -c | sort -nr | head -10 \
    | while read -r count pair; do
      echo "$TODAY,$project,6mo,$pair,change_coupling,$count"
    done >> "$OUTFILE"

  # --- Lines of code (R files only) ---
  loc=$(find "$repo" -name "*.R" -not -path "*renv*" -not -path "*packrat*" 2>/dev/null \
    | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}')
  echo "$TODAY,$project,all,R_files,lines_of_code,${loc:-0}" >> "$OUTFILE"

  # --- Active files: files changed in last 30 days ---
  n_active=$(git -C "$repo" log --format=format: --name-only --since="30 days ago" 2>/dev/null \
    | sort -u | grep -c '[^ ]' || echo "0")
  echo "$TODAY,$project,30d,active_files,files_changed,${n_active:-0}" >> "$OUTFILE"

  # --- Commit message length (avg, last 50 commits) — proxy for commit discipline ---
  avg_msg=$(git -C "$repo" log --format='%s' -50 2>/dev/null \
    | awk '{total+=length($0); n++} END{if(n>0)printf "%d",total/n; else print 0}')
  echo "$TODAY,$project,recent,avg_msg_len,commit_msg_length,${avg_msg:-0}" >> "$OUTFILE"

  # --- Files added (last 6 months) — codebase growth rate ---
  n_added=$(git -C "$repo" log --diff-filter=A --name-only --format='' --since="6 months ago" 2>/dev/null \
    | grep -c '[^ ]' || echo "0")
  echo "$TODAY,$project,6mo,growth,files_added,${n_added:-0}" >> "$OUTFILE"

  # --- Files deleted (last 6 months) — cleanup rate ---
  n_deleted=$(git -C "$repo" log --diff-filter=D --name-only --format='' --since="6 months ago" 2>/dev/null \
    | grep -c '[^ ]' || echo "0")
  echo "$TODAY,$project,6mo,cleanup,files_deleted,${n_deleted:-0}" >> "$OUTFILE"

  # --- Net file growth ---
  echo "$TODAY,$project,6mo,net,files_net_growth,$((${n_added:-0} - ${n_deleted:-0}))" >> "$OUTFILE"

  # --- Change velocity: insertions/deletions in last 30 days ---
  velocity=$(git -C "$repo" log --shortstat --since="30 days ago" --format='' 2>/dev/null \
    | awk '/insertions|deletions/{ins+=$4; del+=$6} END{printf "%d",ins+del}')
  echo "$TODAY,$project,30d,velocity,lines_changed,${velocity:-0}" >> "$OUTFILE"

done

# Convert CSV to Parquet via DuckDB CLI
if command -v duckdb >/dev/null 2>&1; then
  duckdb -c "COPY (SELECT * FROM read_csv('$OUTFILE', sep=',', header=true, all_varchar=true)) TO '$PARQUET' (FORMAT PARQUET);" 2>/dev/null
  if [ -f "$PARQUET" ]; then
    n_rows=$(duckdb -c "SELECT COUNT(*) FROM read_parquet('$PARQUET');" 2>/dev/null | grep -oE '[0-9]+' | tail -1)
    echo "Wrote $PARQUET ($n_rows rows)"
    # Keep CSV for debugging; remove after confirming Parquet works
  else
    echo "WARNING: Parquet conversion failed, keeping CSV at $OUTFILE"
  fi
else
  echo "WARNING: duckdb CLI not found, keeping CSV at $OUTFILE"
fi
