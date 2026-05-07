# /roborev-setup - Configure roborev for Current Project

Set up roborev with proper configuration for the current project.

## Steps

1. Check if roborev hook is installed
2. Create `.roborev.toml` if missing
3. Verify agents are available
4. Report current status

## Commands

```bash
echo "=== roborev Setup: $(basename $PWD) ==="
echo ""

# Check roborev installed (prefer /usr/local/bin, fall back to PATH)
ROBOREV="/usr/local/bin/roborev"
if [ ! -x "$ROBOREV" ]; then
  ROBOREV=$(command -v roborev 2>/dev/null)
fi
if [ -z "$ROBOREV" ] || [ ! -x "$ROBOREV" ]; then
  echo "ERROR: roborev not found"
  exit 1
fi
echo "✓ roborev: $ROBOREV"

# Check hook
if [ -f ".git/hooks/post-commit" ] && grep -q roborev ".git/hooks/post-commit" 2>/dev/null; then
  echo "✓ Hook: installed"
else
  echo "✗ Hook: not installed"
  echo "  Install with: $ROBOREV install-hook"
fi

# Create .roborev.toml if missing
if [ -f ".roborev.toml" ]; then
  echo "✓ Config: .roborev.toml exists"
  cat .roborev.toml
else
  echo "Creating .roborev.toml..."
  cat > .roborev.toml << 'TOML'
# .roborev.toml — per-project roborev config
fix_min_severity = "high"
refine_min_severity = "high"
max_prompt_size = 200000
TOML
  echo "✓ Config: .roborev.toml created"
  echo ""
  echo "Contents:"
  cat .roborev.toml
  echo ""
  echo "Commit with: git add .roborev.toml && git commit -m 'chore: add roborev config'"
fi

echo ""

# Check agents
echo "Agent availability:"
$ROBOREV check-agents 2>/dev/null || echo "  (check-agents not available)"

echo ""

# Current status
echo "Current review status:"
$ROBOREV summary 2>/dev/null || echo "  (no reviews yet)"
```

## Notes

- Run this after `roborev install-hook` to complete setup
- `.roborev.toml` should be committed to share config with team
- Default severity is `high` — adjust in the file if needed
