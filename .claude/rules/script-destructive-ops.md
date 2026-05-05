---
name: script-destructive-ops
description: Every script that runs destructive ops while the user is absent must carry a recovery trail, a reproducibility justification, or an interactive prompt. Covers bin/, .claude/hooks/, .claude/scripts/, and launchd plists.
type: rule
---

# Rule: Recovery Trail for Destructive Script Operations

## Source

JohnGavin/llm#100 (closed): `bin/refresh_and_preserve.sh` ran `git reset --hard` after `git stash create`, but the stash-restore was gated on a branch-switch condition that often did not fire. 37 leaked auto-stashes accumulated since 2026-01-26 before the user noticed. The fix used `git stash create` + `git stash store` + a tracked `STASH_REF` + unconditional restore. That pattern is the reference implementation.

Audit: `.claude/notes/destructive-scripts-audit.md` (2026-05-05) — 7 ops found, 0 MISSING.

## When This Applies

Any script in:
- `bin/` (this project and per-project siblings)
- `.claude/hooks/`
- `.claude/scripts/`
- `~/Library/LaunchAgents/` plists that invoke any of the above

that executes a destructive operation **while the user is not actively watching** (launchd schedule, session_stop hook, periodic refresh).

## CRITICAL: Every Destructive Op Needs One of Three Defences

| Defence | When to use |
|---------|-------------|
| **Recovery trail** | State cannot be regenerated from inputs — git history, user-edited files, accumulated data |
| **Reproducibility justification** | The destroyed state is rebuilt by a known command (`tar_make()`, `nix-build`, `mktemp` cleanup) |
| **Interactive prompt** | Script runs interactively (not from launchd/cron) and the user can confirm |

Default = **recovery trail**. If you cannot argue reproducibility, add a trail.

## The Recovery-Trail Pattern

### Git working-tree wipe (`git reset --hard`)

Copy the reference implementation from `bin/refresh_and_preserve.sh` lines 87-102 and 385-403:

```bash
STASH_REF=""
if ! git diff --quiet || ! git diff --staged --quiet; then
    STASH_MSG="Auto-stash before <script-name> $(date +%Y%m%d_%H%M%S)"
    STASH_REF=$(git -C "$REPO" stash create "$STASH_MSG")
    if [ -n "$STASH_REF" ]; then
        git -C "$REPO" stash store -m "$STASH_MSG" "$STASH_REF"
        git -C "$REPO" reset --hard
        log "Stashed as $STASH_REF"
    fi
fi
# ... do the work ...
# At exit (unconditional — no branch-switch condition):
if [ -n "$STASH_REF" ]; then
    if git -C "$REPO" stash apply "$STASH_REF"; then
        git -C "$REPO" stash drop "stash@{0}" || true
    else
        log "stash apply failed — $STASH_REF retained for manual recovery (90d reflog)"
    fi
fi
```

Key invariants: (1) capture `STASH_REF` before reset, (2) restore is **unconditional** — no `if branch changed` gate, (3) log the ref so the user can recover manually if apply fails.

### File overwrite (JSON, SQL, config)

Copy to a dated backup before overwriting:

```bash
BACKUP="$FILE.$(date +%Y%m%d_%H%M%S).bak"
cp -a "$FILE" "$BACKUP"
echo "$(date) Backed up $FILE to $BACKUP" >> "$LOG"
# ... overwrite $FILE ...
```

Rotate old backups to cap disk usage (keep last N, logged).

### Any destructive op — log it

Every script that touches durable state MUST write to `~/.claude/logs/<script-name>.log`:

```bash
LOG="$HOME/.claude/logs/$(basename "$0" .sh).log"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }
log "START: $0 $*"
log "DESTRUCTIVE: git reset --hard in $REPO (stash $STASH_REF)"
```

## Reproducibility Justification

A script may skip the recovery trail if it documents that the destroyed state is fully regeneratable:

```bash
# REPRODUCIBILITY: $TMPDIR is mktemp -d scratch; output already written to $OUT_FILE.
# Re-running this script regenerates $TMPDIR from $SOURCE with no data loss.
rm -rf "$TMPDIR"
```

Acceptable reproducibility sources:
- `mktemp -d` temporary directories (contents committed to named files before cleanup)
- `_targets/` cache (rebuilt by `tar_make()`)
- Nix build outputs (rebuilt by `nix-build`)
- Fetched-only data with a stable remote source (ccusage JSON, public API)

Not acceptable: user-edited files, uncommitted git state, accumulated DuckDB records, braindump outputs.

## Checklist for Adding a New Script

Before merging any script that contains a destructive op:

- [ ] Is the op destructive? (modifies or deletes durable state irreversibly)
- [ ] Reproducible? Document the regeneration command in a comment adjacent to the op
- [ ] Recovery trail? Copy the stash-create+store or cp-backup pattern; write to log
- [ ] Log entry? `~/.claude/logs/<script>.log` records the op with timestamp and identifiers
- [ ] Tested? Simulate a failure mid-script (kill -9) and verify recovery

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---------|-----------|-----|
| `git reset --hard` without prior `git stash create`+`git stash store` | Uncommitted state lost | Stash-create+store pattern above |
| `git reset --hard` with restore gated on a condition | Condition may not fire | Unconditional restore at script exit |
| `rm -rf <user-data-dir>` without size/age check | Destroys potentially irreplaceable data | `safe-deletion` rule + cp backup |
| Overwriting `.json`/`.sql` with `>` without backup | Silent overwrite of previous version | `cp -a "$FILE" "$FILE.$(date +%Y%m%d).bak"` |
| No log entry for destructive op | No audit trail; debugging impossible | Write to `~/.claude/logs/<script>.log` |
| launchd plist invoking a script with destructive ops and no recovery trail | Runs at 2am, no user to notice | Add trail before scheduling |

## Related

- `.claude/notes/destructive-scripts-audit.md` — v1 audit results (2026-05-05)
- `safe-deletion` — `rm` discipline for interactive contexts (this rule covers scripted/unattended contexts)
- `permission-mode-discipline` — binding Claude's permission mode to workspace type
- `destructive-api-calls` — guard hook that intercepts Claude tool calls with destructive verbs
- `systematic-debugging` — ops paragraph: ops scripts are subject to the same evidence-before-action discipline
