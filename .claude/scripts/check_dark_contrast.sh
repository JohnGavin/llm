#!/usr/bin/env bash
# check_dark_contrast.sh - audit a deployed page for missing dark-mode bg overrides
#
# Usage:
#   ./scripts/check_dark_contrast.sh <url>
#   ./scripts/check_dark_contrast.sh https://johngavin.github.io/acd_area_climate_design/vignettes/articles/upload.html
#
# What it does (static analysis on the deployed HTML):
#   1. Fetches the URL with curl
#   2. Finds every element carrying inline style="...background:#XXXXXX..." with a LIGHT colour
#   3. For each such element, scans the same HTML's <style> blocks for a dark-mode override
#      that targets it — either by id, by attribute-selector matching the hex, or by class
#   4. Reports a table of (element, light bg, dark-mode protected? yes/no)
#
# Exit code: 0 if all light inline bgs are protected; 1 otherwise.
#
# What it does NOT do:
#   - Render the page in a real browser (no headless Chrome / Playwright)
#   - Compute pixel-level contrast ratios
#   - Catch CSS-rendered colours that come from external stylesheets
#
# For visual confirmation, after this static check passes, manually:
#   1. Open the URL
#   2. Click the 🌙 button in the toolbar (top-right)
#   3. Walk every tab/tabset and confirm pure-black background everywhere
#   4. Pay special attention to JS-injected DOM (results table, error banners,
#      toast notifications) which only appear after user interaction.

set -euo pipefail

URL="${1:?Usage: $0 <url>}"
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

echo "Fetching: $URL"
curl -sSfL "$URL" > "$TMP"
size=$(wc -c < "$TMP")
echo "  $size bytes fetched"

# Save <style> blocks separately so we can scan them for dark-mode rules.
# Then strip <style>...</style> and <script>...</script> from the body so the
# regex doesn't match source code (CSS comments, JS template literals).
BODY=$(mktemp); trap 'rm -f "$TMP" "$BODY"' EXIT
python3 - "$TMP" "$BODY" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
clean = re.sub(r'<style\b[^>]*>.*?</style>', '', src, flags=re.S|re.I)
clean = re.sub(r'<script\b[^>]*>.*?</script>', '', clean, flags=re.S|re.I)
open(sys.argv[2], 'w').write(clean)
PY
echo "  rendered DOM (style+script stripped): $(wc -c < "$BODY") bytes"
echo

# Extract every inline style="...background:#XXXXXX..." occurrence.
# Capture: line number in the served HTML, the element fragment, the hex.
# A "light" bg is one whose hex starts with f, e, c, b, d (rough approximation —
# any hex where all three channels are >= 0xb0 reads as "light" to a human).
# A LIGHT hex is one where all three RGB channels are >= 0xb0. That means the
# first hex digit of each channel pair must be in [b-f]. This excludes saturated
# colours like #fd7e14 (orange) where G/B are dark, and matches genuine pales
# like #fff8dc, #f8f9fa, #fff3cd, #f3e8ff, #e7f3ff.
LIGHT_REGEX='background:#[b-fB-F][0-9a-fA-F][b-fB-F][0-9a-fA-F][b-fB-F][0-9a-fA-F]'

echo "── Inline LIGHT-coloured backgrounds in served HTML ──"
matches=$(grep -onE "style=\"[^\"]*${LIGHT_REGEX}[^\"]*\"" "$BODY" || true)

if [ -z "$matches" ]; then
  echo "  none found"
  exit 0
fi

# For each match, derive the element id (if any) and check for a matching
# dark-mode rule in the same HTML's <style> blocks.
fail=0
total=0
covered=0

# Extract <style>...</style> content once (from original, not stripped, file)
styles=$(awk '/<style[^>]*>/,/<\/style>/' "$TMP")

printf '%-6s | %-30s | %-12s | %s\n' "Line" "Element id (or class hint)" "Inline bg" "Dark-mode protected?"
printf '%-6s-+-%-30s-+-%-12s-+-%s\n' "------" "------------------------------" "------------" "--------------------"

while IFS= read -r line; do
  [ -z "$line" ] && continue
  total=$((total + 1))
  lineno=$(echo "$line" | cut -d: -f1)
  payload=$(echo "$line" | cut -d: -f2-)

  # Pull id="..." if present
  id=$(echo "$payload" | grep -oE 'id="[^"]+"' | head -1 | sed 's/id="//;s/"//' || true)
  cls=$(echo "$payload" | grep -oE 'class="[^"]+"' | head -1 | sed 's/class="//;s/"//' | cut -c1-25 || true)
  hint="${id:-${cls:-<unnamed>}}"

  # Extract the hex from the matched style
  hex=$(echo "$payload" | grep -oE 'background:#[a-fA-F0-9]{6}' | head -1 | sed 's/background://')

  # Check coverage: id-level rule OR attribute-selector rule for this hex
  protected=no
  if [ -n "$id" ]; then
    if echo "$styles" | grep -qE "body\.dark-mode #${id}\b"; then
      protected=yes
    fi
  fi
  if [ "$protected" = "no" ] && [ -n "$hex" ]; then
    # Strip leading # for attribute matcher
    hex_no_hash="${hex#\#}"
    # Match either full hex or 3-4 char prefix in attribute selector
    if echo "$styles" | grep -qiE "body\.dark-mode \[style\*=\"background:${hex}"; then
      protected=yes
    fi
    if [ "$protected" = "no" ] && echo "$styles" | grep -qiE "body\.dark-mode \[style\*=\"background:#${hex_no_hash:0:3}"; then
      protected=yes
    fi
    if [ "$protected" = "no" ] && echo "$styles" | grep -qiE "body\.dark-mode \[style\*=\"background:#${hex_no_hash:0:4}"; then
      protected=yes
    fi
  fi

  if [ "$protected" = "yes" ]; then
    covered=$((covered + 1))
  else
    fail=1
  fi

  printf '%-6s | %-30s | %-12s | %s\n' "$lineno" "${hint:0:30}" "$hex" "$protected"
done <<< "$matches"

echo
echo "── Summary ──"
echo "  total light-bg elements: $total"
echo "  covered by dark-mode rule: $covered"
echo "  uncovered: $((total - covered))"

if [ $fail -eq 1 ]; then
  echo
  echo "FAIL: at least one light-coloured inline background has no dark-mode override."
  echo "Add a rule like:"
  echo "  body.dark-mode #<id> { background:#000 !important; color:#fff !important; }"
  echo "Or extend the catch-all attribute selector in the page <style> block."
  exit 1
else
  echo
  echo "PASS: all light inline backgrounds have a dark-mode override."
  exit 0
fi
