# /roborev-list-projects - List All Projects with roborev Enabled

List all projects in `~/docs_gh/` that have the roborev post-commit hook installed.

## Steps

1. Scan all directories in `~/docs_gh/`
2. Check each for `.git/hooks/post-commit` containing "roborev"
3. Report status: enabled, disabled, or no git repo
4. Show summary counts

## Commands

```bash
# Prefer /usr/local/bin/roborev, fall back to PATH
ROBOREV="/usr/local/bin/roborev"
[ ! -x "$ROBOREV" ] && ROBOREV=$(command -v roborev 2>/dev/null)
[ -z "$ROBOREV" ] && { echo "ERROR: roborev not found"; exit 1; }

echo "=== Projects with roborev enabled ==="
echo ""

enabled=0
disabled=0
nogit=0

for repo in ~/docs_gh/*/; do
  name=$(basename "$repo")
  hook="$repo/.git/hooks/post-commit"

  if [ ! -d "$repo/.git" ]; then
    nogit=$((nogit + 1))
    continue
  fi

  if [ -f "$hook" ] && grep -q "roborev" "$hook" 2>/dev/null; then
    # Check for .roborev.toml
    if [ -f "$repo/.roborev.toml" ]; then
      config="✓ .roborev.toml"
    else
      config="⚠ missing .roborev.toml"
    fi

    # Check for pending reviews
    pending=$(cd "$repo" && $ROBOREV list --status failed --limit 100 2>/dev/null | grep -c "^Job" || echo "0")

    echo "✓ $name ($config, $pending pending)"
    enabled=$((enabled + 1))
  else
    echo "✗ $name (hook not installed)"
    disabled=$((disabled + 1))
  fi
done

echo ""
echo "=== Summary ==="
echo "Enabled:  $enabled"
echo "Disabled: $disabled"
echo "No git:   $nogit"
echo ""
echo "To enable: cd <project> && roborev install-hook"
echo "To check:  /roborev status"
```

## Notes

- Projects without `.roborev.toml` should have it added (see `/roborev-setup`)
- Pending count shows failed reviews needing attention
- Use `/roborev-clear-backlog` to clear a project's backlog
