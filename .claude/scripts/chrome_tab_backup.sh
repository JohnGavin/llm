#!/bin/bash
# NOT `#!/usr/bin/env bash` — deliberately (llm: daily TCC prompt).
#
# `env bash` resolves to /opt/homebrew/bin/bash, which is AD-HOC SIGNED. TCC
# stores a grant for an ad-hoc-signed binary with an EMPTY code-requirement
# blob (csreq), because there is no stable designated requirement to record.
# With no csreq, TCC cannot verify tomorrow that the binary asking is the one
# that was authorised yesterday — so it re-prompts. This job runs once a day,
# which is why the prompt appeared once a day:
#
#   $ sqlite3 ~/Library/.../TCC.db \
#       "SELECT client, length(csreq) FROM access
#        WHERE service='kTCCServiceSystemPolicyAppData'"
#   /opt/homebrew/Cellar/bash/5.3.9/bin/bash|      <- empty
#
#   tccd log, same morning:
#   09:00:09 AUTHREQ_PROMPTING service=kTCCServiceSystemPolicyAppData
#            subject=/opt/homebrew/Cellar/bash/5.3.9/bin/bash
#
# /bin/bash is Apple-signed, so its grant carries a real csreq and persists.
# The control on this machine: /bin/bash holds kTCCServiceAppleEvents granted
# 2026-04-28 and never re-prompted since.
#
# The Cellar path is also version-pinned (…/bash/5.3.9/…), so every Homebrew
# bash upgrade would invalidate the grant regardless.
#
# Verified bash-3.2 compatible: no declare -A, mapfile, ${x^^} or other 4+
# constructs, and `/bin/bash -n` is clean. Re-check that before adding any.
# chrome_tab_backup.sh — Daily snapshot of all Chrome tabs (all profiles, all windows)
# Runs via launchd: com.johngavin.chrome-tab-backup
# Output: ~/.chrome-tab-backups/YYYY-MM-DD_HHMMSS.json
# Retention: 90 days

set -uo pipefail

BACKUP_DIR="$HOME/.chrome-tab-backups"
RETENTION_DAYS=90
DATE=$(date '+%Y-%m-%d')
TIME=$(date '+%H%M%S')
OUTFILE="$BACKUP_DIR/${DATE}_${TIME}.json"

mkdir -p "$BACKUP_DIR"

# JXA (JavaScript for Automation): enumerate all windows and tabs with URLs + titles
# Chrome's scripting bridge sees ALL windows across ALL profiles
/usr/bin/osascript -l JavaScript -e '
const chrome = Application("Google Chrome");
const windows = chrome.windows();
const result = [];
for (let i = 0; i < windows.length; i++) {
  const w = windows[i];
  const tabs = w.tabs();
  const tabList = [];
  for (let j = 0; j < tabs.length; j++) {
    tabList.push({ url: tabs[j].url(), title: tabs[j].title() });
  }
  result.push({
    window_index: i,
    window_name: w.name(),
    tab_count: tabs.length,
    tabs: tabList
  });
}
JSON.stringify({
  timestamp: new Date().toISOString(),
  window_count: windows.length,
  total_tabs: result.reduce((s, w) => s + w.tab_count, 0),
  windows: result
}, null, 2);
' > "$OUTFILE" 2>/dev/null

if [ -s "$OUTFILE" ]; then
  TABS=$(/usr/bin/python3 -c "import json; d=json.load(open('$OUTFILE')); print(d['total_tabs'])")
  echo "$(date '+%Y-%m-%d %H:%M:%S') Backed up $TABS tabs to $OUTFILE"
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') WARNING: Chrome not running or no tabs" >&2
  rm -f "$OUTFILE"
  exit 0
fi

# Prune backups older than retention period
find "$BACKUP_DIR" -name "*.json" -mtime +${RETENTION_DAYS} -delete 2>/dev/null
REMAINING=$(ls "$BACKUP_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')
echo "$(date '+%Y-%m-%d %H:%M:%S') Backups on disk: $REMAINING (retention: ${RETENTION_DAYS}d)"
