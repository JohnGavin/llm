# /roborev-clear-backlog - Clear roborev Backlog for a Project

Burn down all open roborev findings for the current project. Runs in BACKGROUND so Claude doesn't wait.

## Arguments

- `$ARGUMENTS` — Optional: project path (defaults to current directory)

## Steps

1. Verify clean working tree and roborev installation
2. Get earliest failed review commit for --since boundary
3. Launch roborev refine in background (codex first, gemini fallback)
4. Return immediately with status check instructions

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

# Get earliest failed review commit for --since (needed on main branch)
SINCE_COMMIT=$($ROBOREV list --status failed --limit 100 2>/dev/null | tail -1 | awk '{print $2}' | cut -c1-7)
if [ -z "$SINCE_COMMIT" ]; then
  echo "No failed reviews found. Nothing to refine."
  exit 0
fi

# Create log file
LOGFILE="/tmp/roborev-backlog-$(basename $PROJECT)-$(date +%Y%m%d_%H%M%S).log"

# Launch in background with codex, fallback to gemini
echo "Launching roborev refine in BACKGROUND..."
echo "  Agent: codex (fallback: gemini)"
echo "  Since: $SINCE_COMMIT"
echo "  Log:   $LOGFILE"
echo ""

nohup bash -c "
  echo '=== roborev refine started: $(date) ===' > '$LOGFILE'
  echo 'Agent: codex (fallback: gemini)' >> '$LOGFILE'
  echo 'Since: $SINCE_COMMIT' >> '$LOGFILE'
  echo '' >> '$LOGFILE'

  cd '$PROJECT'
  if $ROBOREV refine --agent codex --min-severity high --max-iterations 10 --since $SINCE_COMMIT >> '$LOGFILE' 2>&1; then
    echo '' >> '$LOGFILE'
    echo '=== Codex completed successfully ===' >> '$LOGFILE'
  else
    echo '' >> '$LOGFILE'
    echo '=== Codex failed/rate-limited, trying gemini ===' >> '$LOGFILE'
    $ROBOREV refine --agent gemini --min-severity high --max-iterations 10 --since $SINCE_COMMIT >> '$LOGFILE' 2>&1 || true
  fi

  echo '' >> '$LOGFILE'
  echo '=== Finished: $(date) ===' >> '$LOGFILE'
  echo 'Unpushed commits:' >> '$LOGFILE'
  git log origin/\$(git branch --show-current)..HEAD --oneline 2>/dev/null >> '$LOGFILE' || echo '  (none or error)' >> '$LOGFILE'
" > /dev/null 2>&1 &

BGPID=$!
echo "Background PID: $BGPID"
echo ""
echo "Check progress:"
echo "  tail -f $LOGFILE"
echo ""
echo "Check roborev status:"
echo "  $ROBOREV summary"
echo "  $ROBOREV list --status failed"
echo ""
echo "Push fixes when done:"
echo "  git push"
```

## Notes

- Runs in BACKGROUND — Claude returns immediately, no token burn
- Uses codex (cheapest), falls back to gemini if rate limited
- Requires --since flag on main branch (roborev protection)
- Check log file with `tail -f` for progress
- Push commits manually when backlog clear completes
