# Plan: Simplify default.sh

## Current State
- 456 lines
- Good documentation of historical issues in header
- 4-step structure is clear
- Some redundancy and dead code

## Simplification Opportunities

### 1. Remove Dead Code (Lines 453-456)
**Issue:** These echo statements NEVER execute because lines 447/450/451 all use `exec` which replaces the process.
```bash
echo -e "\n=== Exited Nix shell ==="  # DEAD CODE
echo "GC root still active at: $GC_ROOT_PATH"  # DEAD CODE
```
**Action:** Remove entirely.

### 2. Fix Duplicate "Check 5" Labels (Lines 108-114)
**Issue:** Two checks are both labeled "Check 5".
```bash
# Check 5: default.nix still contains escaped PATH...
# Check 5: default.nix exists but has invalid Nix syntax...  # Should be Check 6
```
**Action:** Renumber to Check 5 and Check 6.

### 3. Consolidate HOME Validation Functions
**Issue:** Two similar functions:
- `sanitize_home()` (lines 60-77)
- `is_valid_home()` (lines 218-225)

**Action:** Keep `is_valid_home()` as the utility, refactor `sanitize_home()` to use it.

### 4. Add DEBUG Flag for Verbose Output
**Issue:** Debug echo statements scattered throughout (lines 370-371, 377, 398-400).
**Action:** Add `DEBUG=${DEBUG:-false}` at top, wrap debug echos in `[ "$DEBUG" = true ] && echo ...`

### 5. Consolidate Zsh Config Creation
**Issue:** Similar zsh configs created in two places:
- Wrapper script (lines 329-345)
- Interactive shell setup (lines 420-445)

**Action:** Extract common zsh config to a function or template.

### 6. Lessons Learned Section (Replace Verbose Comments)
The header already has good "HISTORICAL ISSUES FIXED" documentation. Consider:
- Moving detailed fix descriptions to a separate `NIX_LESSONS_LEARNED.md`
- Keeping only brief warnings in the script

## Proposed Simplified Structure

```bash
#!/bin/bash
# default.sh - Nix Environment Setup
# See NIX_LESSONS_LEARNED.md for historical issues and fixes.

set -euo pipefail

# --- Config ---
PROJECT_PATH="/Users/johngavin/docs_gh/llm"
GC_ROOT_PATH="$PROJECT_PATH/nix-shell-root"
DEBUG=${DEBUG:-false}

# --- Functions ---
is_valid_home() { ... }
debug() { [ "$DEBUG" = true ] && echo "$@"; }
create_zsh_config() { ... }
create_bash_config() { ... }

# --- Step 1: Generate default.nix ---
# --- Step 2: Build shell ---
# --- Step 3: Verify GC root ---
# --- Step 4: Launch interactive shell ---
```

## Actual Changes (2026-01-20)

| Change | Lines Saved | Status |
|--------|-------------|--------|
| Remove dead code (post-exec echos) | 3 | ✅ Done |
| Fix duplicate Check 5 label | 0 | ✅ Done |
| Add DEBUG flag + debug() function | +5 | ✅ Done |
| Convert debug echos to debug() | -3 | ✅ Done |
| Consolidate is_valid_home() | -8 | ✅ Done |

**Result:** 456 → 445 lines (11 lines saved, ~2.4% reduction)

**Note:** Conservative changes only. More aggressive consolidation (extracting zsh config to function) deferred to avoid breaking working script.

## Priority
Low - Script works correctly. Further simplification is optional.
