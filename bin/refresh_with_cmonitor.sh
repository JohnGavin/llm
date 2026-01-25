#!/bin/bash
# Enhanced refresh script that combines ccusage and cmonitor data
# Runs via launchd every 12 hours

set -e

# Configuration
LLM_REPO="/Users/johngavin/docs_gh/llm"
LOG_FILE="$LLM_REPO/inst/logs/refresh_combined.log"
LOCK_FILE="/tmp/refresh_combined.lock"

# Source Nix if available
if [ -e "/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh" ]; then
    . "/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh"
fi
if [ -e "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
    . "$HOME/.nix-profile/etc/profile.d/nix.sh"
fi

# Add common paths
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# Ensure only one instance runs
if [ -f "$LOCK_FILE" ]; then
    pid=$(cat "$LOCK_FILE")
    if kill -0 "$pid" 2>/dev/null; then
        echo "$(date): Another instance running (PID $pid), exiting" >> "$LOG_FILE"
        exit 0
    fi
fi
echo $$ > "$LOCK_FILE"
trap "rm -f $LOCK_FILE" EXIT

# Create directories if needed
mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$LLM_REPO/inst/extdata"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $1" | tee -a "$LOG_FILE"
}

log "===== Starting combined refresh ====="

# Change to repo directory
cd "$LLM_REPO"

# 1. Run ccusage refresh via nix-shell
log "Step 1: Refreshing ccusage data"
if nix-shell "$LLM_REPO/default.nix" --attr shell --run "cd $LLM_REPO && Rscript R/scripts/refresh_ccusage_cache.R" >> "$LOG_FILE" 2>&1; then
    log "✓ ccusage refresh completed"
else
    log "⚠ ccusage refresh failed (exit code: $?)"
fi

# 2. Capture cmonitor data (if available)
if command -v cmonitor &> /dev/null; then
    log "Step 2: Capturing cmonitor data"

    # Daily view
    cmonitor --view daily > "$LLM_REPO/inst/extdata/cmonitor_daily.txt" 2>&1 || true

    # Monthly view
    cmonitor --view monthly > "$LLM_REPO/inst/extdata/cmonitor_monthly.txt" 2>&1 || true

    # Session view
    cmonitor --view session > "$LLM_REPO/inst/extdata/cmonitor_session.txt" 2>&1 || true

    log "✓ cmonitor data captured"
else
    log "⚠ cmonitor not found - skipping"
fi

# 3. Check for changes
if git diff --quiet inst/extdata/*.json inst/extdata/*.txt 2>/dev/null; then
    log "No changes to commit"
    exit 0
fi

# 4. Commit and push changes
log "Step 3: Committing changes"
git add inst/extdata/*.json inst/extdata/*.txt 2>/dev/null || true

commit_msg="chore: Auto-refresh usage data $(date '+%Y-%m-%d %H:%M')

Updated ccusage and cmonitor data.
Automated refresh via launchd (12-hourly).

🤖 Generated automatically"

git commit -m "$commit_msg" >> "$LOG_FILE" 2>&1

# Push to remote
log "Step 4: Pushing to remote"
if git push >> "$LOG_FILE" 2>&1; then
    log "✓ Push successful"

    # Log summary stats
    if [ -f "$LLM_REPO/inst/extdata/ccusage_session_all.json" ]; then
        total_cost=$(jq -r '.totals.totalCost // 0' "$LLM_REPO/inst/extdata/ccusage_session_all.json" 2>/dev/null || echo "unknown")
        log "Current total cost: \$$total_cost"
    fi
else
    log "⚠ Push failed - may need manual intervention"
fi

log "===== Refresh complete ====="