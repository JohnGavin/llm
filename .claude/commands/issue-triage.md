# /issue-triage - List GitHub Issues by Difficulty

Analyze all open GitHub issues for the current repository, group them by similarity, and sort from easiest to hardest.

## Steps

1. Fetch all open issues with metadata (labels, comments, age)
2. Group by similarity (labels, keywords, components)
3. Assess difficulty (1-5 stars based on complexity indicators)
4. Present organized triage report

## Execute

```bash
# Get repository info
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)
if [ -z "$REPO" ]; then
    echo "Error: Not in a GitHub repository"
    exit 1
fi

echo "Fetching open issues for $REPO..."

# Fetch all open issues
gh issue list \
    --repo "$REPO" \
    --state open \
    --limit 100 \
    --json number,title,body,labels,comments,createdAt,updatedAt \
    > /tmp/issues.json

TOTAL=$(jq length /tmp/issues.json)
echo "Found $TOTAL open issues"
```

## Analysis Criteria

**Difficulty Assessment:**
- ⭐ = good first issue, typos, documentation
- ⭐⭐ = simple bugs, adding tests
- ⭐⭐⭐ = feature additions, moderate refactoring
- ⭐⭐⭐⭐ = complex bugs, significant refactoring
- ⭐⭐⭐⭐⭐ = architecture changes, core modifications

**Grouping by:**
- Same labels
- Common keywords (test, docs, bug, feature)
- Related components/modules

## Output Format

```
=== ISSUE TRIAGE REPORT ===
Repository: owner/repo
Total Issues: X

GROUP 1: [Theme] (X issues)
  #123 [⭐] Fix typo in README
  #456 [⭐⭐] Add unit tests

GROUP 2: [Theme] (Y issues)
  #789 [⭐⭐⭐] Add new feature
  #101 [⭐⭐⭐⭐] Refactor core module

=== QUICK START (Easiest) ===
1. #123 - Fix typo [⭐]
2. #456 - Add tests [⭐⭐]

=== CHALLENGES (Hardest) ===
1. #101 - Refactor core [⭐⭐⭐⭐]
```

Analyze the fetched JSON data and present actionable recommendations based on difficulty and grouping.