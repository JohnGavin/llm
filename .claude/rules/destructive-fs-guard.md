---
description: Hook-enforced filesystem guard — blocks rm -rf, git clean, git reset --hard on protected paths without a 4-digit confirmation code
paths:
  - ".claude/hooks/**"
  - ".claude/settings*.json"
---

# Rule: Destructive Filesystem Guard (Enforced)

## Source

User feedback 2026-05-07: Advisory rules like `safe-deletion` have no enforcement. An agent can ignore them and execute `rm -rf .claude/` with nothing to stop it. This rule adds **technical enforcement** via a PreToolUse:Bash hook.

## When This Applies

Every Bash command that matches a destructive pattern AND targets a protected path.

## CRITICAL: This Rule Is ENFORCED, Not Advisory

Unlike most rules which depend on the model following instructions, this rule is enforced by `~/.claude/hooks/destructive_fs_guard.sh`. The hook exits non-zero and **blocks the command** unless the user provides a confirmation code.

## Protected Paths

| Path | Why protected |
|------|---------------|
| `.claude/` | Project and global configuration, rules, context state |
| `R/`, `src/` | Source code |
| `packages/` | R package source |
| `data/`, `inst/extdata/` | Data files (may be irreplaceable) |
| `*.nix`, `flake.*` | Nix environment configuration |
| `DESCRIPTION`, `NAMESPACE` | R package metadata |
| `_targets.R`, `_targets/` | Pipeline definition and cache |
| `knowledge/`, `wiki/`, `raw/` | Knowledge base (raw is append-only) |
| `.git/`, `.github/` | Version control |
| `CLAUDE.md`, `CHANGELOG.md`, `README*` | Documentation |

## Destructive Patterns

| Pattern | What it catches |
|---------|-----------------|
| `rm -rf`, `rm -Rf`, `rm -r`, `rm -fr` | Recursive deletion |
| `git clean -fd`, `git clean -fx` | Remove untracked files |
| `git reset --hard` | Discard all uncommitted changes |
| `git checkout -- .`, `git restore .` | Discard working tree changes |

## How Confirmation Works

1. Claude attempts a destructive command on a protected path
2. Hook detects the pattern and generates a **4-digit confirmation code**
3. Hook exits non-zero, displaying a warning with the code
4. Command is BLOCKED
5. User must say "proceed with code XXXX" (typing the code proves they read the warning)
6. Claude re-runs with: `DESTRUCTIVE_CONFIRM=XXXX <command>`
7. Hook validates code matches, allows execution
8. Execution is logged to `~/.claude/logs/destructive_confirmed.log`

## Example Flow

```
Claude: Bash("rm -rf .claude/old_backup/")
Hook:   ⛔ BLOCKED — code 7382 required
        User must say: "proceed with code 7382"

User:   "proceed with code 7382"

Claude: Bash("DESTRUCTIVE_CONFIRM=7382 rm -rf .claude/old_backup/")
Hook:   ✓ Code matches, allowing execution
        [logged to destructive_confirmed.log]
```

## Defense in Depth

| Layer | Protection |
|-------|------------|
| **settings.json deny list** | Blocks direct `rm -rf` (no confirmation path) |
| **destructive_fs_guard.sh** | Handles `DESTRUCTIVE_CONFIRM=...` pattern |
| **Audit log** | All blocked and confirmed commands logged |

The deny list acts as a backstop. If someone removes the hook or it fails to load, direct `rm -rf` is still blocked by the deny list. The `DESTRUCTIVE_CONFIRM=` prefix bypasses the deny list (different command start) but goes through the hook.

## Audit Logs

| Log file | Contents |
|----------|----------|
| `~/.claude/logs/destructive_blocked.log` | Commands blocked with their expected codes |
| `~/.claude/logs/destructive_confirmed.log` | Commands that were confirmed and executed |

Review these logs periodically to understand what destructive operations are being attempted.

## Modifying Protected Paths

To add or remove protected paths, edit `~/.claude/hooks/destructive_fs_guard.sh`:

```bash
PROTECTED_PATHS='(\.claude/|^R/|packages/|...)'
```

## Bypassing (Emergency Only)

If the hook itself is broken and blocking legitimate operations:

1. Temporarily rename: `mv ~/.claude/hooks/destructive_fs_guard.sh ~/.claude/hooks/destructive_fs_guard.sh.disabled`
2. Run the command
3. Restore: `mv ~/.claude/hooks/destructive_fs_guard.sh.disabled ~/.claude/hooks/destructive_fs_guard.sh`

This should be rare — the hook is designed to be conservative (allow if can't parse, only block on explicit matches).

## Related

- `bash-safety` rule — safe-deletion advisory guidance (this rule enforces it)
- `destructive-ops-guard` rule — API-level destructive operations (curl, gh, aws)
- `file_protection.sh` hook — blocks edits to `raw/` folder
- `backup-architecture` rule — backups in different failure domain
