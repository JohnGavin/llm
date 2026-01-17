# Context Control Guide

## Description

Claude Code has a limited context window. Managing context effectively prevents loss of important information and maintains session productivity. This guide covers commands and strategies for context management.

## Purpose

Use this skill when:
- Sessions are getting long and Claude starts forgetting earlier context
- You need to compact conversation history
- You want to rewind to an earlier state
- Managing large codebases efficiently

## Context Commands

### /compact - Compress Conversation

Summarizes the conversation to reduce token usage while preserving key information.

```
/compact
```

**When to use:**
- Session is getting long (50+ exchanges)
- Claude starts forgetting earlier decisions
- Before starting a new major task in the same session

**What happens:**
- Conversation history is summarized
- Key decisions and context are preserved
- Detailed intermediate steps are compressed

### /clear - Reset Context

Clears conversation history completely.

```
/clear
```

**When to use:**
- Starting a completely new task
- Previous context is no longer relevant
- Session has accumulated irrelevant information

**Caution:** All conversation history is lost. Save important information first.

### Escape Commands

Use `Ctrl+C` or `Esc` to:
- Cancel current Claude response
- Interrupt long-running operations
- Break out of loops

### /undo - Rewind Last Action

Undoes the most recent Claude action.

```
/undo
```

**When to use:**
- Claude made an unwanted file change
- Wrong direction taken
- Need to try alternative approach

## Context-Efficient Patterns

### 1. Use Agents for Isolated Tasks

Agents run in separate context, preserving main conversation space:

```
# Instead of doing everything in main context:
# ❌ Long debugging session pollutes main context

# Use agent:
# ✅ Debugging happens in isolated agent context
Task tool with subagent_type=r-debugger
```

### 2. Reference Files Instead of Pasting

```
# ❌ BAD: Pasting large file contents
"Here's my 500-line file: [paste]"

# ✅ GOOD: Reference the file
"Check R/simulate.R for the issue"
# Claude reads file as needed, doesn't bloat context
```

### 3. Summarize Before Context Fills

Before context limit:
1. Ask Claude to summarize decisions made
2. Save summary to `.claude/CURRENT_WORK.md`
3. Run `/compact`
4. Continue with compressed context

### 4. Use TodoWrite for State

Todo list persists across compaction:

```
# Todos survive /compact
TodoWrite([
  {content: "Implement feature X", status: "completed"},
  {content: "Fix bug Y", status: "in_progress"},
  {content: "Add tests", status: "pending"}
])
```

### 5. Checkpoint Important Decisions

```markdown
# .claude/CURRENT_WORK.md

## Session: 2024-01-12

### Decisions Made
- Using mirai instead of furrr for parallelization (lighter weight)
- Data stored in inst/extdata for vignette access
- WASM build verified on r-universe

### Current Task
Implementing dashboard vignette

### Next Steps
1. Add interactivity controls
2. Browser test the Shinylive app
3. Update pkgdown site
```

## Context Budget Management

### Estimate Context Usage

| Content Type | Approximate Tokens |
|--------------|-------------------|
| 1 line of code | ~10 tokens |
| Average R function | ~100-300 tokens |
| Full R file (200 lines) | ~2000 tokens |
| README.md | ~500-1500 tokens |
| Conversation exchange | ~200-500 tokens |

### Context Limits

- Claude's context: ~200k tokens
- Practical limit before degradation: ~100k tokens
- Recommended working range: <50k tokens

### Signs of Context Pressure

- Claude forgets earlier decisions
- Repeated questions about already-discussed topics
- Inconsistent behavior compared to session start
- Slower responses

## Session Continuity Strategy

### Start of Session

```bash
# 1. Check current work
cat .claude/CURRENT_WORK.md

# 2. Review git state
git status
git log --oneline -5

# 3. Load relevant context
# Claude will read CLAUDE.md automatically
```

### During Session

```markdown
# Update .claude/CURRENT_WORK.md every 2-3 hours
# or after major decisions
```

### End of Session

```bash
# 1. Commit or stash work
gert::git_add(".")
gert::git_commit("WIP: session checkpoint")

# 2. Update current work file
# Document: what's done, what's next, key decisions

# 3. Push to remote
gert::git_push()
```

## Advanced Context Control

### Selective File Reading

```
# Instead of reading entire file:
Read file_path with offset=100, limit=50
# Only reads lines 100-150
```

### Use Glob for Discovery

```
# Don't read all files to find something
# Use Glob to find, then read specific files
Glob pattern="R/**/*.R"
# Then read only relevant files
```

### Grep Before Read

```
# Find relevant sections first
Grep pattern="simulate_walk"
# Then read only matching files
```

## Integration with Workflow

Context control supports the 9-step workflow:

- **Step 3 (Make changes)**: Use agents to isolate debugging
- **Step 4 (Run checks)**: Summarize results, don't paste full logs
- **Step 9 (Log everything)**: Checkpoint to files, not just context

## Quick Reference

| Command | Effect | When to Use |
|---------|--------|-------------|
| `/compact` | Compress history | Long sessions |
| `/clear` | Reset context | New task |
| `/undo` | Revert last action | Mistakes |
| `Ctrl+C` | Cancel response | Wrong direction |
| `TodoWrite` | Persist state | Track progress |
| Save to file | External memory | Key decisions |

## Resources

- Session Continuity Guide: `.claude/WIKI_CONTENT/Session-Continuity.md`
- Current Work Template: `.claude/CURRENT_WORK.md`
