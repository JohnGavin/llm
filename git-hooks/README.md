# Global Git Hooks Configuration

This directory contains centralized Git hooks that apply to all repositories on this machine.

## Setup

Run the setup script once to enable global hooks:

```bash
chmod +x ~/docs_gh/llm/git-hooks/setup_global_hooks.sh
~/docs_gh/llm/git-hooks/setup_global_hooks.sh
```

## How It Works

Git's `core.hooksPath` configuration allows you to specify a directory containing hooks that apply to all repositories, instead of using each repo's `.git/hooks/` directory.

## Available Hooks

### pre-commit
Runs before each commit to check for:

**R Package Specific Checks:**
- Large files (>50MB) that should use Git LFS
- Sensitive files (.env, credentials, tokens)
- Test files outside tests/ directory
- nix-shell-root symlink (breaks CI/CD)
- Missing .Rbuildignore entries for Nix files

**Universal Checks:**
- Merge conflict markers
- Debug statements (browser(), console.log, etc.)
- TODO/FIXME comments in new code

## Managing Hooks

### Disable for a specific repository
If a repo needs different hooks or no hooks:
```bash
cd /path/to/repo
git config core.hooksPath .git/hooks
```

### Disable globally
To stop using global hooks:
```bash
git config --global --unset core.hooksPath
```

### Re-enable globally
```bash
git config --global core.hooksPath ~/docs_gh/llm/git-hooks
```

### Check current configuration
```bash
# Global setting
git config --global core.hooksPath

# Local repo override
git config core.hooksPath
```

## Benefits

1. **Consistency**: Same checks across all projects
2. **Maintenance**: Update hooks in one place
3. **Safety**: Prevent common mistakes before they're committed
4. **Flexibility**: Can override per-repository when needed

## Migrating Existing Hooks

If you have existing hooks in projects, you can:

1. Copy unique checks to the global hook
2. Keep project-specific hooks by setting local override:
   ```bash
   git config core.hooksPath .git/hooks
   ```

## Troubleshooting

### Hook not running?
```bash
# Check if hooks are executable
ls -la ~/docs_gh/llm/git-hooks/

# Verify global config
git config --global core.hooksPath

# Check for local override
git config core.hooksPath
```

### Hook blocking valid commit?
- Press Enter to continue past warnings
- Press Ctrl+C to abort and fix
- Or temporarily bypass: `git commit --no-verify`

## Adding New Hooks

1. Create new hook file in `~/docs_gh/llm/git-hooks/`
2. Make it executable: `chmod +x ~/docs_gh/llm/git-hooks/hook-name`
3. Test in a sample repository

## Hook Development Tips

- Use clear error messages with colors
- Distinguish between errors (exit 1) and warnings (continue)
- Check file existence before processing
- Handle both staged and unstaged changes appropriately
- Test with: `git hook run pre-commit`