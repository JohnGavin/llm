#!/bin/bash
# uninstall_ccusage_automation.sh — Remove the dead com.johngavin.ccusage-refresh
# launchd job (llm#900).
#
# WHY: the job's target script, R/scripts/refresh_ccusage_cache.R, was deleted
# in commit 1830f87 (#32, "Remove stale telemetry data migrated to
# llmtelemetry", 2026-02-25). Since then the job has run twice daily, always
# hit "Fatal error: cannot open file ... No such file or directory", and
# always exited 0 anyway (the wrapper script's failure branch deliberately
# does not exit non-zero, so it could still commit partial output — see
# bin/refresh_ccusage_and_commit.sh's git history). Five-plus months of
# silent no-ops.
#
# The data this job would have refreshed (inst/extdata/ccusage_daily_all.json,
# ccusage_session_all.json) is no longer live data to refresh: per
# R/ccusage.R::ccusage_cache_file()'s own documentation, the package-bundled
# "daily"/"session" caches are a DELIBERATELY FROZEN historical snapshot
# (2026-01-10..2026-05-09) — llmtelemetry now owns the live refresh for a
# disjoint, non-overlapping date window, and reconciling the two windows is
# blocked on canonical project-name resolution (llm#652, tracked in llm#870).
# Repairing this job to write into that file would actively corrupt the
# frozen snapshot it is deliberately not supposed to touch. Removal (Option A
# from llm#900), not repair (Option B), is therefore correct.
#
# This script only touches the LIVE launchd installation
# (~/Library/LaunchAgents/), never the git repo. The dead source files
# (bin/com.johngavin.ccusage-refresh.plist, bin/refresh_ccusage_and_commit.sh,
# bin/install_ccusage_automation.sh) are removed from the repo in the same
# commit that adds this script.
#
# USAGE (run manually — NOT invoked automatically):
#   bash bin/uninstall_ccusage_automation.sh [--dry-run]

set -euo pipefail

LABEL="com.johngavin.ccusage-refresh"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_LINK="$LAUNCH_AGENTS_DIR/$LABEL.plist"

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

run() {
  echo "+ $*"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    "$@"
  fi
}

echo "uninstall_ccusage_automation.sh — removing dead job $LABEL (llm#900)"
[[ "$DRY_RUN" -eq 1 ]] && echo "(dry run — no changes will be made)"
echo ""

if [[ -e "$PLIST_LINK" || -L "$PLIST_LINK" ]]; then
  echo "1. Unloading $LABEL (ignore errors if already unloaded)..."
  run launchctl bootout "gui/$(id -u)" "$PLIST_LINK" 2>/dev/null || \
    run launchctl unload "$PLIST_LINK" 2>/dev/null || true

  echo "2. Removing $PLIST_LINK ..."
  run rm -f "$PLIST_LINK"
else
  echo "1-2. $PLIST_LINK not present — nothing to unload/remove."
fi

echo ""
echo "3. Verify it is gone:"
echo "     launchctl print gui/\$(id -u)/$LABEL   # should say 'could not find service'"
echo ""
echo "Done. The stale logs at inst/logs/ccusage_refresh.log,"
echo "inst/logs/ccusage_launchd.log, and inst/logs/ccusage_launchd_error.log"
echo "are left in place as a historical record (not deleted by this script)."
