#!/usr/bin/env bash
# qa_vignette_tabs.sh — QA check for vignette tab content
#
# Usage:
#   qa_vignette_tabs.sh [docs_dir]
#
# Checks all .html files for:
# - Fallback/placeholder content
# - Empty tabs (grid-template-rows: ;)
# - Missing build info
# - TODO/FIXME markers
#
# Directory resolution:
# - Uses provided dir if specified
# - Falls back to vignettes/ then docs/
# - Fails if no HTML files found (not fail-open)

set -euo pipefail

# Resolve directory: prefer vignettes/ over docs/, accept explicit override
if [ -n "${1:-}" ]; then
  DOCS_DIR="$1"
elif [ -d "vignettes" ] && compgen -G "vignettes/*.html" > /dev/null 2>&1; then
  DOCS_DIR="vignettes"
elif [ -d "docs" ] && compgen -G "docs/*.html" > /dev/null 2>&1; then
  DOCS_DIR="docs"
else
  echo "=== Vignette Tab QA Check ==="
  echo "ERROR: No HTML files found in vignettes/ or docs/"
  echo "Run 'quarto render' first to generate HTML output."
  exit 1
fi

ERRORS=0

echo "=== Vignette Tab QA Check ==="
echo "Directory: $DOCS_DIR"
echo

# Verify HTML files exist (fail-closed, not fail-open)
HTML_COUNT=$(find "$DOCS_DIR" -maxdepth 1 -name "*.html" 2>/dev/null | wc -l | tr -d ' ')
if [ "$HTML_COUNT" -eq 0 ]; then
  echo "ERROR: No .html files found in $DOCS_DIR"
  echo "Run 'quarto render' first to generate HTML output."
  exit 1
fi
echo "Found $HTML_COUNT HTML file(s) to check"
echo

# Check 1: Fallback content
echo "1. Checking for fallback/placeholder content..."
FALLBACK_FILES=$(find "$DOCS_DIR" -maxdepth 1 -name "*.html" -exec grep -l "Data not available\|Run tar_make\|not found" {} \; 2>/dev/null || true)
if [ -n "$FALLBACK_FILES" ]; then
    echo "   ERROR: Fallback content found in:"
    echo "$FALLBACK_FILES" | sed 's/^/     /'
    ERRORS=$((ERRORS + 1))
else
    echo "   OK: No fallback content"
fi

# Check 2: Empty tabs (empty grid-template-rows)
echo "2. Checking for empty tabs..."
EMPTY_TABS=$(find "$DOCS_DIR" -maxdepth 1 -name "*.html" -exec grep -l 'grid-template-rows: ;' {} \; 2>/dev/null || true)
if [ -n "$EMPTY_TABS" ]; then
    echo "   ERROR: Empty tabs found in:"
    echo "$EMPTY_TABS" | sed 's/^/     /'
    ERRORS=$((ERRORS + 1))
else
    echo "   OK: No empty tabs"
fi

# Check 3: TODO/FIXME markers
echo "3. Checking for TODO/FIXME markers..."
TODO_FILES=$(find "$DOCS_DIR" -maxdepth 1 -name "*.html" -exec grep -l "TODO\|FIXME\|XXX" {} \; 2>/dev/null | grep -v "node_modules" || true)
if [ -n "$TODO_FILES" ]; then
    echo "   WARN: TODO/FIXME found in:"
    echo "$TODO_FILES" | sed 's/^/     /'
fi

# Check 4: Build info present
echo "4. Checking for build info..."
while IFS= read -r html; do
    [ -z "$html" ] && continue
    if grep -q "Build Info" "$html" 2>/dev/null; then
        # Look for various encodings of "Built</strong> 2026-" or "Built 2026-"
        # Handles: literal </strong>, HTML-escaped &lt;/strong&gt;, or plain text
        if ! grep -qE "Built(</strong>|&lt;/strong&gt;)? 20[0-9][0-9]-" "$html" 2>/dev/null; then
            echo "   ERROR: $html has Build Info tab but no build timestamp"
            ERRORS=$((ERRORS + 1))
        fi
    fi
done < <(find "$DOCS_DIR" -maxdepth 1 -name "*.html" 2>/dev/null)
echo "   OK: Build info checks complete"

# Check 5: Tab 2 / generic tab names
echo "5. Checking for generic tab names..."
GENERIC_TABS=$(find "$DOCS_DIR" -maxdepth 1 -name "*.html" -exec grep -l '>Tab [0-9]<' {} \; 2>/dev/null || true)
if [ -n "$GENERIC_TABS" ]; then
    echo "   ERROR: Generic tab names (Tab 1, Tab 2) found in:"
    echo "$GENERIC_TABS" | sed 's/^/     /'
    ERRORS=$((ERRORS + 1))
else
    echo "   OK: No generic tab names"
fi

echo
if [ "$ERRORS" -gt 0 ]; then
    echo "=== FAILED: $ERRORS error(s) found ==="
    exit 1
else
    echo "=== PASSED: All checks OK ==="
    exit 0
fi
