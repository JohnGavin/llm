# Codex/Claude Shared Folders Runbook

## Goal

Keep Codex running from `~/.codex` as usual, but replace selected Codex folders with symlinks to the existing Claude-managed folders that are already backed by the `llm` repo.

Initial scope:

- `~/.codex/rules` -> `~/.claude/rules`
- `~/.codex/skills` -> `~/.claude/skills`
- `~/.codex/memories` -> `~/.claude/projects/-Users-johngavin-docs-gh-llm/memory`

Out of scope:

- `~/.codex/auth.json`
- `~/.codex/sessions/`
- `~/.codex/state_5.sqlite*`
- `~/.codex/logs_2.sqlite*`
- `~/.codex/log/`
- `~/.codex/cache/`
- `~/.codex/tmp/`
- `~/.codex/.tmp/`

## Recommendation

Use a phased rollout:

1. Move and symlink `rules`
2. Move and symlink `memories`
3. Validate Codex behavior
4. Move and symlink `skills` only after validation

Reason:

- `rules` is the lowest-risk shared surface.
- `memories` should work at the filesystem level, but content conventions may differ.
- `skills` is the highest-risk area because Codex and Claude may not interpret the same skill tree identically.

## Preconditions

Confirm these targets exist:

```bash
ls -ld \
  /Users/johngavin/.claude/rules \
  /Users/johngavin/.claude/skills \
  /Users/johngavin/.claude/projects/-Users-johngavin-docs-gh-llm/memory
```

Confirm `~/.claude/rules` and `~/.claude/skills` already point into the repo:

```bash
ls -ld /Users/johngavin/.claude/rules /Users/johngavin/.claude/skills
```

## Read-Only Policy

Codex is to treat the shared Claude-backed folders as read-only by policy.

If Codex detects or suspects a problem in:

- `.claude/rules/`
- `.claude/skills/`
- `.claude/memory/`

then Codex must:

1. open an `llm` issue
2. describe the incompatibility or risk
3. stop

Codex must not patch those folders directly as part of the same task.

Note:

- Symlinks do not enforce read-only access.
- This runbook defines operational policy, not filesystem enforcement.

## Migration Commands

### Phase 1: `rules`

```bash
mkdir -p /Users/johngavin/.codex/archive/2026-05-22
mv /Users/johngavin/.codex/rules /Users/johngavin/.codex/archive/2026-05-22/rules
ln -s /Users/johngavin/.claude/rules /Users/johngavin/.codex/rules
```

Verify:

```bash
ls -ld /Users/johngavin/.codex/rules
codex doctor --summary --ascii
```

### Phase 2: `memories`

```bash
mv /Users/johngavin/.codex/memories /Users/johngavin/.codex/archive/2026-05-22/memories
ln -s /Users/johngavin/.claude/projects/-Users-johngavin-docs-gh-llm/memory /Users/johngavin/.codex/memories
```

Verify:

```bash
ls -ld /Users/johngavin/.codex/memories
codex doctor --summary --ascii
```

### Phase 3: `skills`

Only do this after Phases 1-2 are stable.

```bash
mv /Users/johngavin/.codex/skills /Users/johngavin/.codex/archive/2026-05-22/skills
ln -s /Users/johngavin/.claude/skills /Users/johngavin/.codex/skills
```

Verify:

```bash
ls -ld /Users/johngavin/.codex/skills
codex doctor --summary --ascii
```

## Full Verification

```bash
ls -ld \
  /Users/johngavin/.codex/rules \
  /Users/johngavin/.codex/skills \
  /Users/johngavin/.codex/memories

codex doctor --summary --ascii
codex mcp get r-btw
```

Expected result:

- `ls -ld` shows symlinks for the migrated paths
- `codex doctor` still reports a healthy config load
- no attempt is made to mutate shared Claude folders

## Rollback

### Roll back `rules`

```bash
rm /Users/johngavin/.codex/rules
mv /Users/johngavin/.codex/archive/2026-05-22/rules /Users/johngavin/.codex/rules
```

### Roll back `memories`

```bash
rm /Users/johngavin/.codex/memories
mv /Users/johngavin/.codex/archive/2026-05-22/memories /Users/johngavin/.codex/memories
```

### Roll back `skills`

```bash
rm /Users/johngavin/.codex/skills
mv /Users/johngavin/.codex/archive/2026-05-22/skills /Users/johngavin/.codex/skills
```

## Known Risks

- `skills` may expose Claude-specific skill structure that Codex does not fully expect.
- `memories` uses a folder name mapping (`memories` -> `memory`) that is valid at the filesystem level but may still reveal tool-level assumptions later.
- Read-only is policy-based, not technically enforced.
- A future Codex or Claude upgrade may change folder expectations and break the arrangement.

## Issue Template

Use this if Codex encounters a problem with the shared folders.

```md
## Summary

Codex encountered an incompatibility while reading a Claude-backed shared folder through `~/.codex`.

## Shared Path

- Codex path:
- Symlink target:
- Repo-backed path:

## Observed Behavior

- Command or action:
- Exact error:
- Whether reproducible:

## Expected Behavior

Describe what Codex should have been able to read or do without modifying the shared folder.

## Impact

- Blocks Codex startup:
- Blocks specific task:
- Degraded but usable:

## Evidence

```text
paste exact error/output here
```

## Policy Check

- No direct edits made to `.claude/rules`, `.claude/skills`, or `.claude/memory`
- Issue filed instead of patching shared content

## Suggested Next Step

- Investigate compatibility in the `llm` repo
- Decide whether to adapt shared content, add a Codex-only compatibility layer, or roll back the symlink
```
