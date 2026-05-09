#!/usr/bin/env bash
# knowledge_pulse.sh - Collect knowledge base metrics
# Writes daily Parquet snapshots to ~/.claude/logs/knowledge/
# Tracks: wiki pages, raw sources, confidence markers, provenance, wiki-links
#
# Usage:
#   knowledge_pulse.sh                    # Snapshot knowledge base
#   knowledge_pulse.sh /path/to/kb        # Custom knowledge base path
#
# Requires: duckdb CLI
# Schedule: daily via cron or launchd
# Related: #122 (Knowledge Base Evolution Dashboard)
#
# Privacy: Knowledge base is local-only. This script captures metrics only,
# not content. Safe to run but outputs stay local.

set -uo pipefail

LOG_DIR="$HOME/.claude/logs/knowledge"
TODAY=$(date +%Y-%m-%d)
OUTFILE="$LOG_DIR/$TODAY.csv"
PARQUET="$LOG_DIR/$TODAY.parquet"
EDGEFILE="$LOG_DIR/${TODAY}_edges.csv"

# Default knowledge base path (can be overridden)
KB_DIR="${1:-$HOME/docs_gh/llm/knowledge}"

mkdir -p "$LOG_DIR"

# Check if knowledge base exists
if [ ! -d "$KB_DIR" ]; then
  echo "Knowledge base not found at $KB_DIR"
  exit 1
fi

WIKI_DIR="$KB_DIR/wiki"
RAW_DIR="$KB_DIR/raw"
OUTPUTS_DIR="$KB_DIR/outputs"

# CSV header
echo "snapshot_date,category,item,metric,value" > "$OUTFILE"

# --- Wiki metrics ---
if [ -d "$WIKI_DIR" ]; then
  # Page count
  n_pages=$(find "$WIKI_DIR" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
  echo "$TODAY,wiki,all,page_count,$n_pages" >> "$OUTFILE"

  # Total words (proxy for content volume)
  total_words=$(find "$WIKI_DIR" -name "*.md" -exec cat {} + 2>/dev/null | wc -w | tr -d ' ')
  echo "$TODAY,wiki,all,word_count,$total_words" >> "$OUTFILE"

  # Total lines
  total_lines=$(find "$WIKI_DIR" -name "*.md" -exec cat {} + 2>/dev/null | wc -l | tr -d ' ')
  echo "$TODAY,wiki,all,line_count,$total_lines" >> "$OUTFILE"

  # Pages with ## Sources section (provenance)
  n_with_sources=$(grep -rl '^## Sources' "$WIKI_DIR" 2>/dev/null | wc -l | tr -d ' ')
  echo "$TODAY,wiki,all,with_sources,$n_with_sources" >> "$OUTFILE"

  # Provenance coverage percentage
  if [ "$n_pages" -gt 0 ]; then
    pct_sourced=$((n_with_sources * 100 / n_pages))
    echo "$TODAY,wiki,all,provenance_pct,$pct_sourced" >> "$OUTFILE"
  fi

  # Pages with AI-inferred markers
  n_ai_inferred=$(grep -rl 'AI-inferred' "$WIKI_DIR" 2>/dev/null | wc -l | tr -d ' ')
  echo "$TODAY,wiki,all,ai_inferred_pages,$n_ai_inferred" >> "$OUTFILE"

  # Total AI-inferred marker count
  total_ai_markers=$(grep -rho 'AI-inferred' "$WIKI_DIR" 2>/dev/null | wc -l | tr -d ' ')
  echo "$TODAY,wiki,all,ai_inferred_markers,$total_ai_markers" >> "$OUTFILE"

  # Wiki-link count (total [[...]] references)
  total_wikilinks=$(grep -rhoE '\[\[[^\]]+\]\]' "$WIKI_DIR" 2>/dev/null | wc -l | tr -d ' ')
  echo "$TODAY,wiki,all,wikilink_count,$total_wikilinks" >> "$OUTFILE"

  # Unique wiki-link targets
  unique_targets=$(grep -rhoE '\[\[[^\]]+\]\]' "$WIKI_DIR" 2>/dev/null | sort -u | wc -l | tr -d ' ')
  echo "$TODAY,wiki,all,wikilink_unique,$unique_targets" >> "$OUTFILE"

  # Pages without any outbound wiki-links (isolated pages)
  n_no_outlinks=$(find "$WIKI_DIR" -name "*.md" -exec sh -c 'grep -qE "\[\[[^\]]+\]\]" "$1" || echo "$1"' _ {} \; 2>/dev/null | wc -l | tr -d ' ')
  echo "$TODAY,wiki,all,no_outlinks,$n_no_outlinks" >> "$OUTFILE"

  # Extract wiki-link graph edges for network visualization
  echo "source,target" > "$EDGEFILE"
  find "$WIKI_DIR" -name "*.md" 2>/dev/null | while read -r filepath; do
    source_name=$(basename "$filepath" .md)
    grep -oE '\[\[[^\]]+\]\]' "$filepath" 2>/dev/null | sed 's/\[\[//g;s/\]\]//g' | while read -r target; do
      echo "$source_name,$target"
    done
  done >> "$EDGEFILE"

  # Edge count (for graph metrics)
  n_edges=$(tail -n +2 "$EDGEFILE" | wc -l | tr -d ' ')
  echo "$TODAY,wiki,graph,edge_count,$n_edges" >> "$OUTFILE"

  # Per-page metrics (top 10 by word count)
  find "$WIKI_DIR" -name "*.md" -exec wc -w {} \; 2>/dev/null \
    | sort -rn | head -10 | while read -r words filepath; do
      name=$(basename "$filepath" .md)
      echo "$TODAY,wiki,$name,words,$words"
    done >> "$OUTFILE"
fi

# --- Raw sources metrics ---
if [ -d "$RAW_DIR" ]; then
  # Source count (any file type)
  n_sources=$(find "$RAW_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
  echo "$TODAY,raw,all,source_count,$n_sources" >> "$OUTFILE"

  # By file type
  for ext in md txt pdf json csv; do
    n_ext=$(find "$RAW_DIR" -name "*.$ext" 2>/dev/null | wc -l | tr -d ' ')
    [ "$n_ext" -gt 0 ] && echo "$TODAY,raw,$ext,count,$n_ext" >> "$OUTFILE"
  done

  # Total size
  total_bytes=$(find "$RAW_DIR" -type f -exec cat {} + 2>/dev/null | wc -c | tr -d ' ')
  echo "$TODAY,raw,all,bytes,$total_bytes" >> "$OUTFILE"

  # Sources added in last 7 days (freshness)
  n_recent=$(find "$RAW_DIR" -type f -mtime -7 2>/dev/null | wc -l | tr -d ' ')
  echo "$TODAY,raw,all,added_7d,$n_recent" >> "$OUTFILE"
fi

# --- Outputs metrics ---
if [ -d "$OUTPUTS_DIR" ]; then
  n_outputs=$(find "$OUTPUTS_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
  echo "$TODAY,outputs,all,count,$n_outputs" >> "$OUTFILE"
fi

# --- Quality metrics ---
if [ -d "$WIKI_DIR" ]; then
  # Confidence distribution: categorize pages
  n_fully_sourced=0
  n_partial=0
  n_unsourced=0

  for f in "$WIKI_DIR"/*.md; do
    [ -f "$f" ] || continue
    has_sources=$(grep -c '^## Sources' "$f" 2>/dev/null || echo "0")
    has_ai=$(grep -c 'AI-inferred' "$f" 2>/dev/null || echo "0")

    if [ "$has_sources" -gt 0 ] && [ "$has_ai" -eq 0 ]; then
      n_fully_sourced=$((n_fully_sourced + 1))
    elif [ "$has_sources" -gt 0 ] && [ "$has_ai" -gt 0 ]; then
      n_partial=$((n_partial + 1))
    else
      n_unsourced=$((n_unsourced + 1))
    fi
  done

  echo "$TODAY,quality,all,fully_sourced,$n_fully_sourced" >> "$OUTFILE"
  echo "$TODAY,quality,all,partial,$n_partial" >> "$OUTFILE"
  echo "$TODAY,quality,all,unsourced,$n_unsourced" >> "$OUTFILE"
fi

# --- Freshness metrics ---
if [ -d "$WIKI_DIR" ]; then
  # Pages not updated in 30 days (stale)
  n_stale=$(find "$WIKI_DIR" -name "*.md" -mtime +30 2>/dev/null | wc -l | tr -d ' ')
  echo "$TODAY,freshness,all,stale_30d,$n_stale" >> "$OUTFILE"

  # Most recently edited page
  newest=$(find "$WIKI_DIR" -name "*.md" -exec stat -f '%m %N' {} \; 2>/dev/null \
    | sort -rn | head -1 | awk '{print $2}')
  if [ -n "$newest" ]; then
    newest_name=$(basename "$newest" .md)
    echo "$TODAY,freshness,newest,page,$newest_name" >> "$OUTFILE"
  fi
fi

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

echo "Edge list written to $EDGEFILE (for network visualization)"
