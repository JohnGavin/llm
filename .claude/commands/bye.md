# /bye - End Session and Exit

Run /session-end checklist then exit Claude Code.

## Usage

Type `/bye` instead of `/exit` to properly end your session.

## Steps

1. **Check Claude config file sizes** (warn if too large)
2. Run /session-end checklist:
   - Check for uncommitted changes
   - Update MEMORY.md session log
   - Log session evidence
   - Prompt for commit/push if needed
3. After session-end completes, inform user to type `/exit` to finish

## Instructions

When this command is invoked:

### Step 1: Check File Sizes

Run this bash command to check Claude-related .md files:

```bash
find ~/.claude -name "*.md" -type f -exec wc -c {} \; 2>/dev/null | sort -rn | head -20
```

**Size Thresholds:**

| Size | Status | Action |
|------|--------|--------|
| < 30KB | ✓ OK | No action needed |
| 30-50KB | ⚠️ Warning | Consider splitting file |
| > 50KB | ❌ Danger | Split immediately - Claude may ignore later sections |

**Files to monitor:**
- `~/.claude/CLAUDE.md` or symlinked `AGENTS.md`
- `~/.claude/skills/*/SKILL.md`
- `~/.claude/rules/*.md`
- `~/.claude/commands/*.md`
- Project `.claude/MEMORY.md` files

**Report format:**
```
## File Size Check

✓ All files under 30KB - OK
  or
⚠️ WARNING: These files are getting large:
  - [filename]: [size]KB - consider splitting

Recommendations:
- Split large skills into SKILL.md + sub-files
- Move detailed examples to separate files
- Use hierarchical directory structure
```

### Step 2: Run /session-end

Invoke the `/session-end` skill to run the end-of-session checklist.

### Step 3: Exit Prompt

After completing all checks, tell the user:
```
Session ended successfully. Type /exit to close Claude Code.
```

## Claude's Implicit File Limits (Reference)

| Limit | Value | Effect |
|-------|-------|--------|
| Read tool default | 2000 lines | Can override with offset/limit |
| Line truncation | 2000 chars | Long lines are cut |
| Context window | ~200K tokens | Total conversation + files |
| Practical per-file | ~50KB | Later sections less attended |
| Aggregate config | ~100K tokens | Earlier context compressed |

**Rule of thumb:** 4 chars ≈ 1 token, so 50KB ≈ 12,500 tokens.

## Note

This is a workaround because Claude Code doesn't have a PreExit hook type.
The Stop hook runs AFTER exit, so it can't invoke Claude skills.
