---
paths:
  - ".claude/rules/destructive-ops-guard.md"
---

# Companion: Destructive Operations Guard

Supporting detail split out of the always-loaded [`destructive-ops-guard`](../destructive-ops-guard.md) rule (llm baseline trim, 2026-10-03).

## Moved from the `destructive-ops-guard` rule body (2026-10-03, always-loaded baseline trim)

Verbatim text removed from the rule body to cut the always-loaded instruction baseline. The normative requirement is restated in the rule; this is the supporting detail.

### Safety-critical tier: scoping history and incident source

This rule was scoped to `.claude/hooks/**`, `bin/**`, `.claude/scripts/**`.
Parts 1-2 (hook-level API blocking, recovery trails) are backed by
deterministic hooks (`destructive_api_guard.sh`, `destructive_fs_guard.sh`)
that fire regardless of what the rule loads for — but Part 3 (two-key
confirmation for `git reset --hard`, force-push, and other irreversible ops)
applies to any Bash call and has no equivalent hook; it depends entirely on
the model recalling this rule at the moment of the call. Scoped to
hooks/bin/scripts paths, it never loaded when Part 3 actually mattered. Per
[llm#943](https://github.com/JohnGavin/llm/issues/943), this rule is now in
the **safety-critical tier** declared in AGENTS.md's "Safety-critical rules"
line and carries no `paths:` frontmatter — it loads into every session and
every subagent, matching the mandatory tier's contract.

Consolidated from: `destructive-api-calls`, `script-destructive-ops`, `two-key-irreversible-ops`.

Source: PocketOS / Cursor / Railway incident 2026-04-25 — agent deleted production volume via single GraphQL mutation in 9 seconds.

### Recovery-Trail (git, files) and Logging patterns (verbatim code)

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


## Moved from the `destructive-ops-guard` rule body (2026-10-03, always-loaded baseline trim)

Verbatim text removed from the rule body to cut the always-loaded instruction baseline. The normative requirement is restated in the rule; this is the supporting detail.

### Blocked Patterns (regex table)

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
