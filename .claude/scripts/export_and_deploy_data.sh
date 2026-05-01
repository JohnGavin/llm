#!/usr/bin/env bash
# export_and_deploy_data.sh — Export local telemetry data and push to trigger deploy
# Called from session_stop.sh hook or manually
# Exports data that only exists locally (predictions, unified.duckdb, cmonitor-rs)
# then commits to llmtelemetry repo and pushes (CI deploys automatically)

set -uo pipefail

TELEMETRY_REPO="$HOME/docs_gh/llmtelemetry"
DATA_DIR="$TELEMETRY_REPO/vignettes/data"
EXPORT_SCRIPT="$TELEMETRY_REPO/inst/scripts/export_dashboard_data.R"

# Quick check: is the repo available?
if [ ! -d "$TELEMETRY_REPO/.git" ]; then
  echo "TELEMETRY: repo not found at $TELEMETRY_REPO"
  exit 0
fi

# Check if export script exists
if [ ! -f "$EXPORT_SCRIPT" ]; then
  echo "TELEMETRY: export script not found"
  exit 0
fi

# Run export (from repo root so here::here() works)
echo "TELEMETRY: exporting dashboard data..."
(cd "$TELEMETRY_REPO" && timeout 120 Rscript "$EXPORT_SCRIPT" 2>&1) | tail -5

# Check if any data files changed
CHANGED=$(git -C "$TELEMETRY_REPO" diff --name-only -- vignettes/data/ 2>/dev/null | wc -l | tr -d ' ')
UNTRACKED=$(git -C "$TELEMETRY_REPO" ls-files --others --exclude-standard -- vignettes/data/ 2>/dev/null | wc -l | tr -d ' ')

if [ "$CHANGED" -eq 0 ] && [ "$UNTRACKED" -eq 0 ]; then
  echo "TELEMETRY: no data changes"
  exit 0
fi

echo "TELEMETRY: $CHANGED changed, $UNTRACKED new data files"

# Commit data-only changes
git -C "$TELEMETRY_REPO" add vignettes/data/*.json
git -C "$TELEMETRY_REPO" commit -m "data: update telemetry data $(date +%Y-%m-%d)

Auto-exported from local sources (predictions, unified.duckdb, cmonitor-rs).
Triggered by session-end hook." --no-verify 2>/dev/null

if [ $? -eq 0 ]; then
  # Push (triggers CI deploy)
  git -C "$TELEMETRY_REPO" push 2>/dev/null
  if [ $? -eq 0 ]; then
    echo "TELEMETRY: data pushed, CI will deploy"
  else
    echo "TELEMETRY: push failed (network?), data committed locally"
  fi
else
  echo "TELEMETRY: nothing to commit"
fi
