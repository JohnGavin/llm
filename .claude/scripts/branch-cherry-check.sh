#!/usr/bin/env bash
# branch-cherry-check.sh — runnable companion to branch-salvage-workflow rule.
# Usage: branch-cherry-check.sh <branch> [repo-path]
#
# Runs the 3-step pre-salvage check from `branch-salvage-workflow.md`:
#   1. patch-id check (git cherry)
#   2. closing-PR check (gh issue view if branch references #N)
#   3. unique-strings check (grep main for distinctive content from branch diff)
#
# Prints a verdict: DISCARD / SALVAGE CANDIDATE / INVESTIGATE.
# Exit code: 0 = DISCARD (safe to delete), 1 = SALVAGE/INVESTIGATE (act before deleting), 2 = usage error.

set -e

if [ $# -lt 1 ]; then
    echo "Usage: $0 <branch> [repo-path]" >&2
    echo "" >&2
    echo "Runs the 3-step pre-salvage check on <branch>." >&2
    echo "If [repo-path] is omitted, uses current working directory." >&2
    exit 2
fi

BRANCH="$1"
REPO="${2:-$(pwd)}"

if ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
    echo "ERROR: $REPO is not a git repository" >&2
    exit 2
fi

if ! git -C "$REPO" rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
    echo "ERROR: branch $BRANCH not found in $REPO" >&2
    exit 2
fi

echo "=== Branch salvage check: $BRANCH (repo: $REPO) ==="
echo

# -------- Step 1: patch-id check --------
echo "--- Step 1: patch-id check (git cherry main $BRANCH) ---"
cherry_out=$(git -C "$REPO" cherry main "$BRANCH" 2>&1)
new_count=$(echo "$cherry_out" | grep -c '^+' || true)
old_count=$(echo "$cherry_out" | grep -c '^-' || true)

echo "$cherry_out"
echo "Result: $new_count genuinely-new patches, $old_count already-applied patches"
echo

if [ "$new_count" -eq 0 ] && [ "$old_count" -gt 0 ]; then
    echo "VERDICT: DISCARD"
    echo "Reason: all $old_count commits already in main via patch-id match. Safe to delete."
    exit 0
fi

# -------- Step 2: closing-PR check --------
echo "--- Step 2: closing-PR check ---"
issue_num=$(git -C "$REPO" log "$BRANCH" --oneline -10 | grep -oE '#[0-9]+' | head -1 | tr -d '#' || true)

if [ -z "$issue_num" ]; then
    # Try the branch name itself
    issue_num=$(echo "$BRANCH" | grep -oE 'issue[-_]?([0-9]+)' | grep -oE '[0-9]+' | head -1 || true)
fi

STEP2_DISCARD=0
STEP2_CLOSING_PR=""

if [ -n "$issue_num" ]; then
    echo "Branch references issue #$issue_num"
    if command -v gh >/dev/null 2>&1; then
        repo_slug=$(git -C "$REPO" remote get-url origin | sed -E 's|.*github\.com[:/]([^/]+/[^/.]+)(\.git)?.*|\1|')
        if [ -n "$repo_slug" ]; then
            state=$(gh issue view "$issue_num" --repo "$repo_slug" --json state --jq '.state' 2>/dev/null || echo "UNKNOWN")
            echo "Issue #$issue_num state: $state"
            if [ "$state" = "CLOSED" ] || [ "$state" = "MERGED" ]; then
                echo "Issue closed — checking for merged PRs that close issue #$issue_num..."
                # Look for merged PRs linked to this issue
                closed_prs=$(gh pr list --repo "$repo_slug" \
                    --search "is:merged closes:#$issue_num" \
                    --json number,mergeCommit,headRefName \
                    --limit 5 2>/dev/null || echo "")
                if [ -z "$closed_prs" ] || [ "$closed_prs" = "[]" ]; then
                    # Fallback: search by issue reference in PR body/title
                    closed_prs=$(gh pr list --repo "$repo_slug" \
                        --search "is:merged #$issue_num" \
                        --json number,mergeCommit,headRefName \
                        --limit 5 2>/dev/null || echo "")
                fi
                if [ -n "$closed_prs" ] && [ "$closed_prs" != "[]" ]; then
                    echo "Found merged PR(s) linked to issue #$issue_num:"
                    echo "$closed_prs" | python3 -c "
import sys, json
prs = json.load(sys.stdin)
for pr in prs:
    mc = pr.get('mergeCommit') or {}
    oid = mc.get('oid', 'unknown')[:12]
    print(f\"  PR #{pr['number']} ({pr['headRefName']}) merge-commit: {oid}\")
" 2>/dev/null || echo "$closed_prs"
                    # Get branch diff paths to check for overlap with merged PR
                    branch_diff_files=$(git -C "$REPO" diff --no-ext-diff "main...$BRANCH" --name-only 2>/dev/null | grep -vE '\.(png|pdf|lock|duckdb|rds|RDS|Rds)$' | head -20)
                    if [ -n "$branch_diff_files" ]; then
                        # For each merged PR, check if it touches overlapping files
                        pr_numbers=$(echo "$closed_prs" | python3 -c "
import sys, json
prs = json.load(sys.stdin)
for pr in prs:
    print(pr['number'])
" 2>/dev/null || true)
                        for pr_num in $pr_numbers; do
                            pr_files=$(gh pr view "$pr_num" --repo "$repo_slug" --json files --jq '.files[].path' 2>/dev/null || echo "")
                            if [ -n "$pr_files" ]; then
                                # Check for file overlap
                                overlap=0
                                while IFS= read -r bfile; do
                                    if echo "$pr_files" | grep -qxF "$bfile" 2>/dev/null; then
                                        overlap=$((overlap + 1))
                                    fi
                                done <<< "$branch_diff_files"
                                if [ "$overlap" -gt 0 ]; then
                                    echo "  PR #$pr_num overlaps $overlap file(s) with candidate branch — likely squash-merged"
                                    STEP2_DISCARD=1
                                    STEP2_CLOSING_PR="$pr_num"
                                    break
                                fi
                            fi
                        done
                    fi
                    if [ "$STEP2_DISCARD" -eq 0 ]; then
                        echo "  No file overlap detected; proceeding to Step 3 for confirmation"
                    fi
                else
                    echo "No merged PRs found linked to issue #$issue_num"
                    echo "WARNING: issue closed but no closing PR found — branch may still have unique work"
                fi
            fi
        fi
    else
        echo "(gh CLI not available — skip)"
    fi
else
    echo "No issue reference found in branch name or recent commits"
fi
echo

if [ "$STEP2_DISCARD" -eq 1 ]; then
    echo "VERDICT: DISCARD"
    echo "Reason: issue #$issue_num is closed and PR #$STEP2_CLOSING_PR touches overlapping files — likely squash-merged."
    exit 0
fi

# -------- Step 3: unique-strings check --------
echo "--- Step 3: unique-strings check ---"
# Derive search paths from the branch diff itself (only text files the branch touches)
diff_paths=$(git -C "$REPO" diff --no-ext-diff "main...$BRANCH" --name-only 2>/dev/null \
    | grep -vE '\.(png|jpg|jpeg|gif|svg|pdf|lock|duckdb|rds|RDS|Rds|parquet|zip|tar|gz|bin|so|dylib)$' \
    | tr '\n' ' ')

if [ -z "$diff_paths" ]; then
    diff_paths="."
fi

# Take 5 distinctive added strings from the branch diff (limit to text paths)
# shellcheck disable=SC2086
added_lines=$(git -C "$REPO" diff --no-ext-diff "main...$BRANCH" -- $diff_paths 2>/dev/null | grep -E '^\+[^+]' | grep -vE '^\+\s*$|^\+\s*(#|//|--|\*)' | head -20)

if [ -z "$added_lines" ]; then
    echo "(no added lines to sample — branch may delete only)"
    echo
    echo "VERDICT: INVESTIGATE"
    echo "Reason: $new_count new patches but no added content. Inspect manually."
    exit 1
fi

# Pull 3 representative strings (16-60 chars, not too generic)
sample_strings=$(echo "$added_lines" | sed 's/^+//' | awk '{ s=$0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); if (length(s) >= 16 && length(s) <= 80) print s }' | head -3)

if [ -z "$sample_strings" ]; then
    echo "(could not extract distinctive strings — branch may use very common patterns)"
    echo
    echo "VERDICT: INVESTIGATE"
    exit 1
fi

found_in_main=0
total_strings=0
while IFS= read -r str; do
    total_strings=$((total_strings + 1))
    # Search main checkout for this string — only in paths the branch touches
    # shellcheck disable=SC2086
    matches=$(git -C "$REPO" grep -c -F -- "$str" main -- $diff_paths 2>/dev/null | awk -F: '{s+=$2} END {print s+0}')
    if [ "$matches" -gt 0 ]; then
        found_in_main=$((found_in_main + 1))
        echo "  IN MAIN: \"$str\" ($matches matches)"
    else
        echo "  NEW: \"$str\""
    fi
done <<< "$sample_strings"

echo
echo "Result: $found_in_main of $total_strings sample strings already in main"
echo

# -------- Verdict --------
if [ "$total_strings" -gt 0 ] && [ "$found_in_main" -eq "$total_strings" ]; then
    echo "VERDICT: DISCARD"
    echo "Reason: all sample strings already in main — likely re-implemented via different PR."
    exit 0
elif [ "$found_in_main" -gt 0 ]; then
    echo "VERDICT: INVESTIGATE"
    echo "Reason: partial overlap — $found_in_main/$total_strings strings in main. Read the diff before deciding."
    exit 1
else
    echo "VERDICT: SALVAGE CANDIDATE"
    echo "Reason: $new_count new patches, no strings in main. Work appears genuinely new."
    exit 1
fi
