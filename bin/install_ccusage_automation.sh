#!/bin/bash
# Install ccusage auto-refresh automation
# This sets up a launchd agent to refresh ccusage cache hourly
# and commit changes to the llm repo automatically.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST_NAME="com.johngavin.ccusage-refresh.plist"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"

echo "Installing ccusage auto-refresh automation..."

# 1. Make the refresh script executable
echo "1. Making refresh script executable..."
chmod +x "$SCRIPT_DIR/refresh_ccusage_and_commit.sh"

# 2. Create LaunchAgents directory if needed
mkdir -p "$LAUNCH_AGENTS_DIR"

# 3. Copy plist to LaunchAgents
echo "2. Installing launchd agent..."
cp "$SCRIPT_DIR/$PLIST_NAME" "$LAUNCH_AGENTS_DIR/"

# 4. Unload if already loaded (ignore errors)
launchctl unload "$LAUNCH_AGENTS_DIR/$PLIST_NAME" 2>/dev/null || true

# 5. Load the agent
echo "3. Loading launchd agent..."
launchctl load "$LAUNCH_AGENTS_DIR/$PLIST_NAME"

# 6. Create log directory
mkdir -p "$(dirname "$SCRIPT_DIR")/../inst/logs"

echo ""
echo "Installation complete!"
echo ""
echo "The ccusage cache will now be refreshed:"
echo "  - Every hour"
echo "  - On system startup/login"
echo ""
echo "Logs are written to:"
echo "  - inst/logs/ccusage_refresh.log"
echo "  - inst/logs/ccusage_launchd.log"
echo ""
echo "To manually trigger a refresh:"
echo "  launchctl start com.johngavin.ccusage-refresh"
echo ""
echo "To check status:"
echo "  launchctl list | grep ccusage"
echo ""
echo "To uninstall:"
echo "  launchctl unload ~/Library/LaunchAgents/$PLIST_NAME"
echo "  rm ~/Library/LaunchAgents/$PLIST_NAME"
