# /roborev-clear-backlog - Clear roborev Backlog for a Project

Burn down all open roborev findings for the current project or a specified project.

## Arguments

- `$ARGUMENTS` — Optional: project path (defaults to current directory)

## Steps

1. Identify the target project
2. Get the earliest commit to set the --since boundary
3. Run roborev refine with codex agent (cheapest)
4. If codex hits rate limit, fall back to gemini
5. Push all fix commits
6. Report summary

## Commands

```bash
PROJECT="${1:-$PWD}"
cd "$PROJECT" || { echo "ERROR: Cannot cd to $PROJECT"; exit 1; }

echo "=== roborev Backlog Clear: $(basename $PROJECT) ==="
echo ""

# Check roborev is installed (prefer /usr/local/bin, fall back to PATH)
ROBOREV="/usr/local/bin/roborev"
[ ! -x "$ROBOREV" ] && ROBOREV=$(command -v roborev 2>/dev/null)
if [ -z "$ROBOREV" ] || [ ! -x "$ROBOREV" ]; then
  echo "ERROR: roborev not found"
  exit 1
fi
echo "Using: $ROBOREV"

# Check hook is enabled
if [ ! -f ".git/hooks/post-commit" ] || ! grep -q roborev ".git/hooks/post-commit" 2>/dev/null; then
  echo "WARN: roborev hook not installed in this project"
  echo "Install with: $ROBOREV install-hook"
fi

# Get current state
echo "Current state:"
$ROBOREV summary 2>/dev/null || echo "  (no roborev data)"
echo ""

# Check for clean working tree
if ! git diff --quiet || ! git diff --staged --quiet; then
  echo "ERROR: Working tree not clean. Commit or stash changes first."
  echo "Pending changes: $(git status --short | wc -l | tr -d ' ')"
  exit 1
fi

# Run refine with codex (cheapest agent)
# Note: --all-branches and --since are mutually exclusive
echo "Running: $ROBOREV refine --agent codex --min-severity high --max-iterations 10"
echo ""

if $ROBOREV refine --agent codex --min-severity high --max-iterations 10; then
  echo ""
  echo "✓ Codex refine completed"
else
  echo ""
  echo "⚠ Codex may have hit rate limit. Trying gemini..."
  $ROBOREV refine --agent gemini --min-severity high --max-iterations 10 || true
fi

# Check for unpushed commits
unpushed=$(git log origin/$(git branch --show-current)..HEAD --oneline 2>/dev/null | wc -l | tr -d ' ')
if [ "$unpushed" -gt 0 ]; then
  echo ""
  echo "$unpushed unpushed fix commit(s). Push now? [y/N]"
  read -r answer
  if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
    git push
    echo "✓ Pushed"
  else
    echo "Skipped. Push manually with: git push"
  fi
fi

echo ""
echo "=== Final state ==="
$ROBOREV summary 2>/dev/null || echo "  (no roborev data)"
```

## Notes

- Uses `--all-branches` to capture findings across all branches
- Starts with codex (cheapest), falls back to gemini if rate limited
- Does NOT auto-push — prompts for confirmation
- Run `roborev refine --agent claude-code` for stubborn findings codex can't fix
