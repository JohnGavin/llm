# /roborev-setup - Configure roborev for Current Project

Set up roborev with proper configuration for the current project.

## Prerequisites (gemini — required for fallback chain, fixes llm#283)

The intended fallback order is `codex → gemini → claude-code (last resort)`.
For this to work, the gemini-cli binary must be installed AND trusted for headless use:

```bash
# 1. Install gemini-cli via Homebrew
/opt/homebrew/bin/brew install gemini-cli

# 2. Authenticate with Google account
gemini auth login

# 3. Trust all directories for headless use (required for roborev daemon)
#    Add to ~/.launchd_env.sh or your shell profile:
export GEMINI_CLI_TRUST_WORKSPACE=true

# 4. Add GEMINI_CLI_TRUST_WORKSPACE=true to the roborev auto-refine launchd plist:
#    Edit ~/Library/LaunchAgents/com.roborev.auto-refine.plist
#    Add under EnvironmentVariables: GEMINI_CLI_TRUST_WORKSPACE = true
#    Then: launchctl bootout gui/$(id -u)/com.roborev.auto-refine
#           launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.roborev.auto-refine.plist

# 5. Set review_backup_agent explicitly (fixes llm#283):
roborev config set --global review_backup_agent gemini
roborev config set --global refine_backup_agent gemini
roborev config set --global fix_backup_agent gemini

# 6. Verify
roborev check-agents   # gemini should show OK
```

Note: `default_backup_agent = 'gemini'` in `~/.roborev/config.toml` is
already correct. The above steps fill in the per-operation backup keys
(`review_backup_agent`, etc.) to make the chain explicit.

## Steps

1. Check if roborev hook is installed
2. Create `.roborev.toml` if missing
3. Verify agents are available (including gemini)
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

# Warn if gemini is not available (fixes llm#283)
if ! command -v gemini >/dev/null 2>&1; then
  echo ""
  echo "WARNING: gemini binary not found in PATH."
  echo "  The fallback chain codex → gemini → claude-code requires gemini-cli installed."
  echo "  Install with: /opt/homebrew/bin/brew install gemini-cli"
  echo "  Then: gemini auth login"
  echo "  And set: GEMINI_CLI_TRUST_WORKSPACE=true in your launchd env"
  echo "  See: /roborev-setup Prerequisites section above for full steps."
fi

echo ""

# Current status
echo "Current review status:"
$ROBOREV summary 2>/dev/null || echo "  (no reviews yet)"
```

## Notes

- Run this after `roborev install-hook` to complete setup
- `.roborev.toml` should be committed to share config with team
- Default severity is `high` — adjust in the file if needed
- gemini-cli must be installed for the intended fallback chain to work (llm#283)
