# Rule: Braindump Closed-Loop Processing

## When This Applies

Every session start where Phase 13 surfaces unprocessed braindumps ("ACTION: N unprocessed braindump(s)").

## CRITICAL: Every Braindump Must Complete the Full Lifecycle

A braindump that is surfaced but not acted on is worse than one never captured — it creates a false sense of completeness. The loop is:

```
Capture → Interpret → Act → Record → Complete
```

## Required Steps (In Order)

### 1. Interpret

Read the raw text. Decide what it means. Determine which project(s) it applies to.

### 2. Process

Record the interpretation:
```bash
~/.claude/scripts/braindump_act.sh process <id> "<structured summary>"
```

The summary MUST include:
- What the instruction means (not just the raw text)
- Which project(s) it targets
- What action type it requires (issue, review, test, investigate, informational)

### 3. Act

Do the work: create issues, edit files, run commands, whatever the braindump requires.

### 4. Record Each Action

For each action taken, link it back:
```bash
# If you created an issue:
~/.claude/scripts/braindump_act.sh action <braindump_id> issue <project> <issue_url> <issue_number>

# If the action is informational (no issue needed):
~/.claude/scripts/braindump_act.sh action <braindump_id> informational <project>

# Other action types: review, test, investigate
~/.claude/scripts/braindump_act.sh action <braindump_id> <type> <project>
```

### 5. Complete (when the work is done)

When the linked issue is closed or the action is finished:
```bash
~/.claude/scripts/braindump_act.sh complete <action_id> "<what happened>"
```

## When Braindumps Reference Other Projects

If a braindump says "work on project X" but Claude is running in project Y:

| Approach | When to use |
|----------|------------|
| Act from current session via `git -C`, agents, Bash | Simple changes (create issue, read files, small edits) |
| Tell user to open a new session in project X | Complex work requiring full project context |
| Spawn an agent with `isolation: "worktree"` | Medium complexity, can be delegated |

In all cases, record the action with `braindump_act.sh` BEFORE ending the current session.

## Session-End Check

`session_stop.sh` will warn if braindumps were surfaced but not processed during this session. This is a safety net — the primary responsibility is on Claude to process them as they're surfaced.

## Forbidden Patterns

| Pattern | Why wrong |
|---------|-----------|
| Reading a braindump and doing nothing | Instruction captured but never acted on |
| Acting on a braindump without calling `braindump_act.sh process` | No record of interpretation |
| Creating an issue without `braindump_act.sh action` | Action not linked to braindump |
| Leaving braindumps for "next session" | Defeats the purpose of real-time capture |
| Processing as "informational" to avoid work | Only genuine notes are informational |

## Related

- `analysis-rationale-mandatory` rule — decision logging pattern
- `verification-before-completion` rule — verify before claiming done
- #88 — braindump processing architecture
- #89 — periodic review and staleness tracking
