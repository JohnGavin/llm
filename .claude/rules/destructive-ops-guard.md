# Rule: Destructive Operations Guard

## Safety-Critical Tier — Loads Unconditionally (No `paths:`)

Per [llm#943](https://github.com/JohnGavin/llm/issues/943), this rule is in the **safety-critical tier** declared in AGENTS.md and carries no `paths:` frontmatter, so it loads into every session and subagent. Parts 1-2 are backed by deterministic hooks (`destructive_api_guard.sh`, `destructive_fs_guard.sh`), but Part 3 (two-key confirmation) has no hook and depends on the model recalling this rule at the moment of the call. Consolidated from `destructive-api-calls`, `script-destructive-ops`, `two-key-irreversible-ops`. Source: PocketOS / Cursor / Railway incident 2026-04-25 (an agent deleted a production volume via one GraphQL mutation in 9 seconds).

---

## Part 1: Hook-Level API Blocking

### CRITICAL: Advisory Rules Are Not Enough

A rule that says "don't do X" is ignored by a sufficiently confident agent.
Hook-level enforcement exits non-zero *before* the command reaches the shell.

### Blocked Patterns

The `PreToolUse:Bash` hook `~/.claude/hooks/destructive_api_guard.sh` blocks the HTTP mutation verbs DELETE, PATCH and PUT on curl and `gh api`, GraphQL `mutation {` POSTs, `aws s3 rb|rm` and `aws ... delete-*`, `flyctl volumes destroy`, `railway volumes delete|destroy`, `psql -c` with DROP/TRUNCATE, and `duckdb`/`sqlite3` DROP/TRUNCATE. Exact regex table: companion doc.

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

### Recovery-Trail and Logging Patterns

Git: `git stash create` + `git stash store` before any `reset --hard`, and `stash apply` at exit UNCONDITIONALLY (report `Retained: <ref>` if apply fails). Files: `cp -a "$FILE" "$FILE.$(date +%Y%m%d_%H%M%S).bak"` before overwriting. **Logging (mandatory):** every destructive op writes a `DESTRUCTIVE:` line to `~/.claude/logs/<script>.log`. Verbatim code: companion doc.

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
