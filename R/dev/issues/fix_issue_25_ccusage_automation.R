# Fix for Issue #25: ccusage automated refresh failing silently
# Date: 2026-01-26
# Author: Claude with John Gavin

# PROBLEM:
# The automated ccusage refresh job (launchd) was failing silently since Jan 22.
# Data was being updated but never committed/pushed to GitHub.

# ROOT CAUSES:
# 1. Script ran on whatever branch was checked out (not always main)
# 2. Git operations failed without proper error logging
# 3. No recovery mechanism for git conflicts or uncommitted changes

# INVESTIGATION:
library(gert)
library(jsonlite)

# 1. Check launchd job status
system("/bin/launchctl list | grep ccusage")
# Output showed exit code 1 (error) instead of 0 (success)

# 2. Examine logs
log_file <- "/Users/johngavin/docs_gh/llm/inst/logs/refresh_preserve.log"
error_log <- "/Users/johngavin/docs_gh/llm/inst/logs/refresh_preserve_error.log"

# Found that commits were failing after "Committing changes..." with no error

# 3. Check last successful auto-refresh
system("git log --oneline --grep='Auto-refresh' | head -5")
# Last successful: Jan 22

# SOLUTION:
# Created improved script: bin/refresh_and_preserve_fixed.sh
# Key improvements:
# - Always switches to main branch
# - Stashes uncommitted changes before operations
# - Pulls latest changes from origin
# - Comprehensive error logging to separate file
# - Returns to original branch after completion
# - Restores stashed changes

# IMPLEMENTATION:

# 1. Create fixed script with proper branch management
fixed_script <- "bin/refresh_and_preserve_fixed.sh"
# [Script content created with proper error handling and branch management]

# 2. Update launchd configuration
plist_path <- "~/Library/LaunchAgents/com.johngavin.ccusage-refresh.plist"
# Updated to use refresh_and_preserve_fixed.sh

# 3. Reload launchd agent
system("/bin/launchctl unload ~/Library/LaunchAgents/com.johngavin.ccusage-refresh.plist")
system("/bin/launchctl load ~/Library/LaunchAgents/com.johngavin.ccusage-refresh.plist")

# VERIFICATION:

# 1. Test the fixed script
system("timeout 60 ./bin/refresh_and_preserve_fixed.sh")

# 2. Check job status (should show exit code 0)
system("/bin/launchctl list | grep ccusage")
# Output: -	0	com.johngavin.ccusage-refresh  ✓

# 3. Verify data is current
blocks_data <- fromJSON("inst/extdata/ccusage_blocks_all.json")
tail(blocks_data$blocks$start_date)
# Shows data through Jan 26 ✓

# MONITORING:
# Future runs can be monitored with:
# tail -f ~/docs_gh/llm/inst/logs/refresh_preserve.log
# tail -f ~/docs_gh/llm/inst/logs/refresh_preserve_error.log

# LESSONS LEARNED:
# 1. Always handle branch management in automated scripts
# 2. Add comprehensive error logging for debugging
# 3. Test automation scripts with various git states
# 4. Follow the 9-step workflow to ensure proper PR notifications