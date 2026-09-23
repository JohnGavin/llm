# /roborev-setup - Configure roborev for Current Project

Set up roborev with proper configuration for the current project.

## Prerequisites (gemini — required for fallback chain, fixes llm#283)

**⚠ Superseded by llm#746 (2026-07-08) — read before setting any `*_backup_agent`.**
Pointing a `*_backup_agent` at `gemini` (or any provider) is only safe if the
corresponding `*_backup_model` is ALSO set explicitly. Otherwise the backup
silently inherits the PRIMARY agent's pinned model (e.g. a `review_model_thorough`
pin like `gemini-2.5-flash-lite`) instead of its own default — a claude-code
backup then dies with `404 model_not_found`, and a gemini/codex backup just
fails the same quota error the primary already hit. This poisoned every review
in #746 until the backup was pinned explicitly. The current live global config
(`~/.roborev/config.toml`) and this repo's `.roborev.toml` both use
`*_backup_agent = 'claude-code'` + `*_backup_model = 'sonnet'` (review/refine/fix)
as the verified-working combo — do NOT reset these back to `gemini` without also
setting a gemini-specific `*_backup_model`, or you reintroduce #746. See the
`roborev-gemini-dead-silent-failure` memory for the full incident history.

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

# 5. Set the backup agent AND its own model explicitly (see #746 warning above —
#    never set *_backup_agent without also pinning *_backup_model):
roborev config set --global review_backup_agent claude-code
roborev config set --global review_backup_model sonnet
roborev config set --global refine_backup_agent claude-code
roborev config set --global refine_backup_model sonnet
roborev config set --global fix_backup_agent claude-code
roborev config set --global fix_backup_model sonnet

# 6. Verify
roborev check-agents   # claude-code should show OK
```

Note: `default_backup_agent = 'claude-code'` in `~/.roborev/config.toml` is
the current correct value (changed from `gemini` per #746 — gemini quota
outages otherwise take the whole fallback chain down with them). The steps
above fill in the per-operation backup keys (`review_backup_agent`, etc.)
with their own model pins so a fallback never inherits a poisoned model.

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
