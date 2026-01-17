#!/bin/bash
# Refresh ccusage cache and commit to llm repo
# This script is designed to run automatically via launchd
# See: ~/Library/LaunchAgents/com.johngavin.ccusage-refresh.plist

set -e

# Configuration
LLM_REPO="/Users/johngavin/docs_gh/llm"
LOG_FILE="$LLM_REPO/inst/logs/ccusage_refresh.log"
LOCK_FILE="/tmp/ccusage_refresh.lock"

# Source Nix if available
if [ -e "/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh" ]; then
    . "/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh"
fi
if [ -e "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
    . "$HOME/.nix-profile/etc/profile.d/nix.sh"
fi

# Add common paths for Homebrew and system tools
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

# Create log directory if needed
mkdir -p "$(dirname "$LOG_FILE")"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $1" >> "$LOG_FILE"
}

log "Starting ccusage refresh"

# Change to repo directory
cd "$LLM_REPO"

# Check if we're in a git repo
if [ ! -d ".git" ]; then
    log "ERROR: Not a git repository: $LLM_REPO"
    exit 1
fi

# Check for npx (needed for ccusage)
if ! command -v npx &> /dev/null; then
    log "ERROR: npx not found. Trying nix-shell..."
fi

# Use nix-shell to run the refresh script (ensures R and npx are available)
log "Running refresh_ccusage_cache.R via nix-shell"
if nix-shell "$LLM_REPO/default.nix" --attr shell --run "cd $LLM_REPO && Rscript R/scripts/refresh_ccusage_cache.R" >> "$LOG_FILE" 2>&1; then
    log "Refresh completed successfully"
else
    log "ERROR: Refresh script failed (exit code: $?)"
    # Don't exit - still try to commit any partial updates
fi

# Check if there are changes to commit
if git diff --quiet inst/extdata/ccusage_*.json 2>/dev/null; then
    log "No changes to commit"
    exit 0
fi

# Stage and commit changes
log "Committing updated cache files"
git add inst/extdata/ccusage_*.json

# Create commit with timestamp
commit_msg="chore: Auto-refresh ccusage cache $(date '+%Y-%m-%d %H:%M')"
git commit -m "$commit_msg" >> "$LOG_FILE" 2>&1

# Push to remote (on current branch)
log "Pushing to remote"
if git push >> "$LOG_FILE" 2>&1; then
    log "Push successful"
else
    log "WARNING: Push failed - may need manual intervention"
    # Common reason: not on a branch that tracks remote
fi

log "Done"
