#!/bin/bash
# Hook: Validate vignettes have no inline computation
# Per quarto-files.md: "MANDATORY: Vignettes contain ZERO computation"
#
# This hook checks for forbidden patterns in vignettes before commit.
# Place in .claude/hooks/ for global enforcement or .git/hooks/pre-commit for per-project.
#
# EXCEPTIONS ALLOWED:
# - targets introspection: tar_visnetwork(), tar_meta(), tar_manifest(), etc.
# - These only read metadata, not computed data

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Find vignettes directory
VIGNETTES_DIR="${1:-vignettes}"

if [ ! -d "$VIGNETTES_DIR" ]; then
  echo -e "${YELLOW}No vignettes directory found, skipping vignette validation${NC}"
  exit 0
fi

echo "Checking vignettes for inline computation..."
echo -e "${BLUE}Note: targets introspection functions (tar_visnetwork, tar_meta, etc.) are allowed${NC}"
echo ""

ERRORS=0

# Check each vignette file
for file in "$VIGNETTES_DIR"/*.Rmd "$VIGNETTES_DIR"/*.qmd; do
  [ -f "$file" ] || continue

  filename=$(basename "$file")

  # Skip setup chunk detection - we only flag non-setup chunks
  # Extract non-setup chunks and check for forbidden patterns

  # Check for assignments (<-) outside setup chunk
  # Exclude lines that are comments or in setup chunk definition
  assignment_count=$(grep -c '<-' "$file" 2>/dev/null | head -1 || echo "0")

  # Allow 1-2 assignments for safe_tar_read definition in setup
  # Allow more if file contains tar_meta/tar_visnetwork (pipeline telemetry vignette)
  if grep -q 'tar_visnetwork\|tar_meta\|tar_manifest\|tar_network' "$file" 2>/dev/null; then
    # Pipeline introspection vignette - allow more assignments for metadata processing
    if [ "$assignment_count" -gt 10 ]; then
      echo -e "${RED}ERROR: $filename has $assignment_count assignments (<-)${NC}"
      echo "       Even pipeline vignettes should minimize computation"
      ERRORS=$((ERRORS + 1))
    fi
  elif [ "$assignment_count" -gt 3 ]; then
    echo -e "${RED}ERROR: $filename has $assignment_count assignments (<-)${NC}"
    echo "       Vignettes should use tar_load()/tar_read() only"
    ERRORS=$((ERRORS + 1))
  fi

  # Check for ggplot() construction (should be pre-computed)
  # EXCEPTION: Allow if paired with tar_meta() for pipeline timing plots
  if grep -q 'ggplot(' "$file" 2>/dev/null; then
    if grep -q 'tar_meta\|tar_visnetwork' "$file" 2>/dev/null; then
      echo -e "${BLUE}INFO: $filename has ggplot() with targets introspection (allowed)${NC}"
    else
      ggplot_count=$(grep -c 'ggplot(' "$file" 2>/dev/null || echo "0")
      echo -e "${RED}ERROR: $filename has $ggplot_count ggplot() calls${NC}"
      echo "       Plots should be pre-computed in targets pipeline"
      ERRORS=$((ERRORS + 1))
    fi
  fi

  # Check for dplyr verbs that suggest inline computation
  # EXCEPTION: Allow if processing tar_meta() output
  for verb in "group_by(" "summarise(" "summarize(" "mutate(" "filter(" "select("; do
    if grep -q "$verb" "$file" 2>/dev/null; then
      count=$(grep -c "$verb" "$file" 2>/dev/null || echo "0")
      if grep -q 'tar_meta\|tar_manifest' "$file" 2>/dev/null; then
        echo -e "${BLUE}INFO: $filename has $count $verb calls on targets metadata (allowed)${NC}"
      else
        echo -e "${YELLOW}WARNING: $filename has $count $verb calls${NC}"
        echo "         Verify these are on pre-loaded data, not computing inline"
      fi
    fi
  done

  # Check for DBI queries - NO EXCEPTION
  if grep -q 'dbGetQuery\|dbExecute\|DBI::' "$file" 2>/dev/null; then
    echo -e "${RED}ERROR: $filename has database queries${NC}"
    echo "       All data must come from targets pipeline"
    ERRORS=$((ERRORS + 1))
  fi

  # Check for forbidden library() calls in executed chunks
  # ALLOWED: library(targets), library(DT) — needed for tar_read/tar_load and display
  # FORBIDDEN: any other library() in executed code chunks
  # Non-executed chunks (eval=FALSE / eval: false) are exempt
  LIBRARY_ALLOWLIST="targets DT"

  # Read package name from DESCRIPTION if present
  PKG_NAME=""
  if [ -f "DESCRIPTION" ]; then
    PKG_NAME=$(grep '^Package:' DESCRIPTION 2>/dev/null | sed 's/^Package:[[:space:]]*//')
  fi

  # Use awk to extract library() calls from executed chunks only
  bad_libs=$(awk '
    BEGIN { in_chunk = 0; eval_off = 0 }
    /^```\{r/ {
      in_chunk = 1
      eval_off = 0
      if ($0 ~ /eval[[:space:]]*=[[:space:]]*FALSE/ || $0 ~ /eval:[[:space:]]*false/) {
        eval_off = 1
      }
      next
    }
    /^```[[:space:]]*$/ {
      in_chunk = 0
      eval_off = 0
      next
    }
    in_chunk && !eval_off && /library\(/ {
      # Extract package name from library(pkg) or library("pkg")
      match($0, /library\(["'"'"']?([A-Za-z0-9._]+)["'"'"']?\)/, arr)
      if (arr[1] != "") print arr[1]
    }
  ' "$file" 2>/dev/null)

  if [ -n "$bad_libs" ]; then
    while IFS= read -r lib; do
      allowed=0
      for ok in $LIBRARY_ALLOWLIST; do
        if [ "$lib" = "$ok" ]; then
          allowed=1
          break
        fi
      done
      if [ "$allowed" -eq 0 ]; then
        echo -e "${RED}ERROR: $filename has library($lib) in an executed chunk${NC}"
        if [ -n "$PKG_NAME" ] && [ "$lib" = "$PKG_NAME" ]; then
          echo "       library($PKG_NAME) is never needed — vignettes do zero computation"
        else
          echo "       Only library(targets) and library(DT) are allowed in executed chunks"
        fi
        echo "       Move to an eval: false chunk if this is a user-facing example"
        ERRORS=$((ERRORS + 1))
      fi
    done <<< "$bad_libs"
  fi

  # --- Check for empty sections: heading immediately followed by code chunk ---
  empty_sections=$(awk '
    /^#{2,4} / { heading=$0; next }
    /^```\{r/ { if (heading != "") { print FILENAME ": " heading; } heading="" ; next }
    /^[[:space:]]*$/ { next }
    { heading="" }
  ' "$file" 2>/dev/null)

  if [ -n "$empty_sections" ]; then
    while IFS= read -r line; do
      echo -e "${RED}ERROR: Empty section (heading with no prose before code chunk)${NC}"
      echo "       $line"
      ERRORS=$((ERRORS + 1))
    done <<< "$empty_sections"
  fi

  # --- Check that every vignette has at least one captioned table or plot ---
  if ! grep -qE 'fig\.cap|fig-cap|caption\s*=' "$file" 2>/dev/null; then
    echo -e "${RED}ERROR: $filename has no captioned tables or plots${NC}"
    echo "       Every vignette must have at least one captioned figure or table"
    ERRORS=$((ERRORS + 1))
  fi

  # --- Check for missing changelog footer ---
  if ! grep -q 'vig_git_changelog' "$file" 2>/dev/null; then
    echo -e "${YELLOW}WARNING: $filename missing vig_git_changelog footer${NC}"
  fi

  # --- Check for user instructions in analysis vignettes ---
  # Exempt: README, introduction, how-to vignettes
  case "$filename" in
    README*|*intro*|*how-to*|*getting-started*) ;;
    *)
      if grep -qE 'Run `?targets::tar_make|Run `?tar_make\(\)|Execute `?devtools::' "$file" 2>/dev/null; then
        echo -e "${YELLOW}WARNING: $filename contains user instructions (e.g., 'Run tar_make()')${NC}"
        echo "         Analysis vignettes should explain outputs, not instruct users"
      fi
      ;;
  esac

done

if [ $ERRORS -gt 0 ]; then
  echo ""
  echo -e "${RED}Found $ERRORS vignette validation errors${NC}"
  echo "See quarto-files.md rule: 'MANDATORY: Vignettes contain ZERO computation'"
  echo ""
  echo "Fix by:"
  echo "  1. Move computation to R/tar_plans/plan_vignette_outputs.R"
  echo "  2. Run tar_make() to build targets"
  echo "  3. Use tar_read('target_name') in vignettes"
  exit 1
fi

echo -e "${GREEN}All vignettes pass validation${NC}"
exit 0
