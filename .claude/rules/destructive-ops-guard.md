---
description: Block destructive API calls, require recovery trails for scripts, two-key confirmation for irreversible ops
paths:
  - ".claude/hooks/**"
  - "bin/**"
  - ".claude/scripts/**"
---

# Rule: Destructive Operations Guard

Consolidated from: `destructive-api-calls`, `script-destructive-ops`, `two-key-irreversible-ops`.

Source: PocketOS / Cursor / Railway incident 2026-04-25 — agent deleted production volume via single GraphQL mutation in 9 seconds.

---

## Part 1: Hook-Level API Blocking

### CRITICAL: Advisory Rules Are Not Enough

A rule that says "don't do X" is ignored by a sufficiently confident agent.
Hook-level enforcement exits non-zero *before* the command reaches the shell.

### Blocked Patterns

The `PreToolUse:Bash` hook `~/.claude/hooks/destructive_api_guard.sh` blocks:

| Pattern | Catches |
|---|---|
| `curl .* -X (DELETE\|PATCH\|PUT)` | curl mutation verbs |
| `curl .* -X POST .* mutation[[:space:]]*\{` | GraphQL mutations |
| `gh api .* -X (DELETE\|PATCH\|PUT)` | gh api destructive verbs |
| `aws s3 (rb\|rm)` | S3 bucket/object delete |
| `aws .* delete-` | aws delete-* subcommands |
| `flyctl volumes? destroy` | fly.io volume destroy |
| `railway volumes? (delete\|destroy)` | railway volume delete |
| `psql.*-c.*(DROP\|TRUNCATE)` | psql destructive SQL |
| `(duckdb\|sqlite3).*(DROP\|TRUNCATE)` | local DB destructive SQL |

### Escape Hatch

When genuinely required:
1. Document intent in the script
2. Run from terminal outside Claude Code
3. For irreversible infrastructure deletes, require two-key confirmation (Part 3)

---

## Part 2: Script Recovery Trails

### When This Applies

Scripts in `bin/`, `.claude/hooks/`, `.claude/scripts/`, or launchd plists that execute destructive operations while user is absent.

### CRITICAL: Every Destructive Op Needs One Defence

| Defence | When to use |
|---------|-------------|
| **Recovery trail** | State cannot be regenerated — git history, user files, accumulated data |
| **Reproducibility justification** | Destroyed state rebuilt by `tar_make()`, `nix-build`, `mktemp` cleanup |
| **Interactive prompt** | Script runs interactively |

### Recovery-Trail Pattern (Git)

```bash
STASH_REF=""
if ! git diff --quiet || ! git diff --staged --quiet; then
    STASH_MSG="Auto-stash before script $(date +%Y%m%d_%H%M%S)"
    STASH_REF=$(git -C "$REPO" stash create "$STASH_MSG")
    if [ -n "$STASH_REF" ]; then
        git -C "$REPO" stash store -m "$STASH_MSG" "$STASH_REF"
        git -C "$REPO" reset --hard
    fi
fi
# ... work ...
# At exit (UNCONDITIONAL):
if [ -n "$STASH_REF" ]; then
    git -C "$REPO" stash apply "$STASH_REF" || echo "Retained: $STASH_REF"
fi
```

### Recovery-Trail Pattern (Files)

```bash
BACKUP="$FILE.$(date +%Y%m%d_%H%M%S).bak"
cp -a "$FILE" "$BACKUP"
# ... overwrite $FILE ...
```

### Logging (Mandatory)

```bash
LOG="$HOME/.claude/logs/$(basename "$0" .sh).log"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }
log "DESTRUCTIVE: git reset --hard in $REPO (stash $STASH_REF)"
```

---

## Part 3: Two-Key Confirmation

### CRITICAL: User Supplies Target Name

For irreversible ops, the user must type the target name from memory. Agent MUST NOT print target name in the same turn as the confirmation prompt.

### Op Classes

| Class | Examples | Confirmation |
|---|---|---|
| **A** — catastrophic | `DROP TABLE users`; delete prod volume; `gh repo delete` | Target name + out-of-band ack |
| **B** — destructive, recoverable | `rm -rf` >100MB; `git reset --hard`; force-push | Target name in phrase |
| **C** — fully reproducible | Clear `_targets/`; delete `/tmp/` | Standard "Are you sure?" |

### Forbidden Patterns

| Pattern | Why wrong |
|---|---|
| Agent prints target in confirmation, accepts echo | Same-turn echo = single principal |
| Agent accepts "yes/y/ok" for Class A/B | No target recall |
| Agent retries after refusal | Persistence pressure |

---

## Related

- `permission-discipline` — workspace modes, MCP scopes, environment context
- `bash-safety` — `rm` discipline, compound commands
- Hook: `~/.claude/hooks/destructive_api_guard.sh`
