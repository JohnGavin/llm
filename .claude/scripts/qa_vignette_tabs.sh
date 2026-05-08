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

set -euo pipefail

DOCS_DIR="${1:-docs}"
ERRORS=0

echo "=== Vignette Tab QA Check ==="
echo "Directory: $DOCS_DIR"
echo

# Check 1: Fallback content
echo "1. Checking for fallback/placeholder content..."
FALLBACK_FILES=$(grep -rl "Data not available\|Run tar_make\|not found" "$DOCS_DIR"/*.html 2>/dev/null || true)
if [ -n "$FALLBACK_FILES" ]; then
    echo "   ERROR: Fallback content found in:"
    echo "$FALLBACK_FILES" | sed 's/^/     /'
    ERRORS=$((ERRORS + 1))
else
    echo "   OK: No fallback content"
fi

# Check 2: Empty tabs (empty grid-template-rows)
echo "2. Checking for empty tabs..."
EMPTY_TABS=$(grep -l 'grid-template-rows: ;' "$DOCS_DIR"/*.html 2>/dev/null || true)
if [ -n "$EMPTY_TABS" ]; then
    echo "   ERROR: Empty tabs found in:"
    echo "$EMPTY_TABS" | sed 's/^/     /'
    ERRORS=$((ERRORS + 1))
else
    echo "   OK: No empty tabs"
fi

# Check 3: TODO/FIXME markers
echo "3. Checking for TODO/FIXME markers..."
TODO_FILES=$(grep -rl "TODO\|FIXME\|XXX" "$DOCS_DIR"/*.html 2>/dev/null | grep -v "node_modules" || true)
if [ -n "$TODO_FILES" ]; then
    echo "   WARN: TODO/FIXME found in:"
    echo "$TODO_FILES" | sed 's/^/     /'
fi

# Check 4: Build info present
echo "4. Checking for build info..."
for html in "$DOCS_DIR"/*.html; do
    if [ -f "$html" ]; then
        if grep -q "Build Info" "$html" 2>/dev/null; then
            # Look for "Built</strong> 2026-" or "Built 2026-" patterns
            if ! grep -qE "Built(<\/strong>)? 20[0-9][0-9]-" "$html" 2>/dev/null; then
                echo "   ERROR: $html has Build Info tab but no build timestamp"
                ERRORS=$((ERRORS + 1))
            fi
        fi
    fi
done
echo "   OK: Build info checks complete"

# Check 5: Tab 2 / generic tab names
echo "5. Checking for generic tab names..."
GENERIC_TABS=$(grep -l '>Tab [0-9]<' "$DOCS_DIR"/*.html 2>/dev/null || true)
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
