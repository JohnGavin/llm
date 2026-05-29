#!/usr/bin/env bash
# launchd_run_record_install.sh — Show suggested wrapper adoptions for owned plists.
#
# For each ~/Library/LaunchAgents/com.claude.*.plist, prints the suggested
# ProgramArguments change to wrap the command with launchd_run_record.sh.
#
# This script is READ-ONLY (it never edits plists automatically).
# Review the suggestions and apply manually.
#
# Tracked in llm#300.

set -euo pipefail

PLIST_DIR="${PLIST_DIR:-$HOME/Library/LaunchAgents}"
WRAPPER="${WRAPPER:-$HOME/docs_gh/llm/bin/launchd_run_record.sh}"
PLUTIL="${PLUTIL:-/usr/bin/plutil}"

echo "# Suggested ProgramArguments wrapper adoptions"
echo "# Script: launchd_run_record_install.sh"
echo "# Review carefully before applying. DO NOT apply automatically."
echo ""

for plist in "$PLIST_DIR"/com.claude.*.plist; do
  [[ -f "$plist" ]] || continue
  [[ "$plist" == *.bak-* ]] && continue

  label=$(basename "$plist" .plist)
  tmpjson=$(mktemp /tmp/plist_install.XXXXXX.json)
  "$PLUTIL" -convert json -o "$tmpjson" "$plist" 2>/dev/null || { rm -f "$tmpjson"; continue; }

  # Extract current ProgramArguments
  prog_args=$(python3 -c "
import json, sys
with open('$tmpjson') as f:
    d = json.load(f)
args = d.get('ProgramArguments', [])
for a in args:
    print(a)
" 2>/dev/null)

  rm -f "$tmpjson"

  # Check if already wrapped
  if echo "$prog_args" | grep -q "launchd_run_record"; then
    echo "## $label  ← already wrapped"
    echo ""
    continue
  fi

  echo "## $label"
  echo "Current ProgramArguments:"
  echo "$prog_args" | sed 's/^/  /'
  echo ""
  echo "Suggested replacement:"
  echo "  /bin/bash"
  echo "  $WRAPPER"
  echo "  $label"
  echo "  --"
  echo "$prog_args" | sed 's/^/  /'
  echo ""
  echo "Plist key block:"
  echo "  <key>ProgramArguments</key>"
  echo "  <array>"
  echo "    <string>/bin/bash</string>"
  echo "    <string>$WRAPPER</string>"
  echo "    <string>$label</string>"
  echo "    <string>--</string>"
  while IFS= read -r arg; do
    echo "    <string>$arg</string>"
  done <<< "$prog_args"
  echo "  </array>"
  echo ""
done

echo "# Review complete. Apply changes manually with a text editor or plutil."
echo "# Then: launchctl unload <plist> && launchctl load <plist>"
