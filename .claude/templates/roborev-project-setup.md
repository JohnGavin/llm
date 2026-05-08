# Template: roborev Project Setup

## Steps to enable roborev on a new project

### 1. Install hook

```bash
# Option A: Subshell (isolates the cd — see bash-safety rule)
(cd /path/to/project && roborev install-hook)

# Option B: If already in project directory
roborev install-hook
```

### 2. Create `.roborev.toml`

```toml
# .roborev.toml — per-project roborev config
fix_min_severity = "high"
refine_min_severity = "high"
max_prompt_size = 200000
```

Commit this file so all contributors share the same config.

### 3. Verify agents available

```bash
roborev check-agents
```

Expect at least `claude-code` and `codex` to show OK. If codex shows "not found":
- Ensure `/usr/local/bin/codex` wrapper exists (see `roborev-resolution` rule)
- Set `codex_cmd = '/usr/local/bin/codex'` in `~/.roborev/config.toml`

### 4. Create knowledge base (for complex projects)

```bash
mkdir -p knowledge/raw knowledge/wiki
```

Create `knowledge/INDEX.md`:
```markdown
# Project Name — Knowledge Base

## Wiki Pages
(add as findings accumulate)

## Log
See [LOG.md](LOG.md) for chronological entries.
```

Create `knowledge/LOG.md`:
```markdown
# Discovery Log

## YYYY-MM-DD
### First finding
- Details here
```

### 5. Test the workflow

```bash
# Make a small commit (assumes cwd is the project root)
# Note: For agents, use git -C /path/to/project for each command
echo "# test" >> README.md
git add README.md
git commit -m "test: verify roborev hook"

# Wait for review (~1 min)
roborev list --limit 1

# Check result
roborev show <job-id>
```

**Agent note:** When scripting, use `git -C /path/to/project` instead of `cd && git`:
```bash
git -C /path/to/project add README.md
git -C /path/to/project commit -m "test: verify roborev hook"
```

### 6. Initial backlog (if existing project)

```bash
# Check current state
roborev summary

# If backlog exists, burn down high-severity
# Note: Quoting $FIRST_COMMIT ensures --since receives the complete SHA
FIRST_COMMIT=$(git log --oneline --reverse | head -1 | cut -d' ' -f1)
roborev refine --agent codex --min-severity high --max-iterations 10 --since "$FIRST_COMMIT" --quiet

# Push fixes
git push
```

## Ongoing Maintenance

Per-session checklist (automated via `session_init.sh` Phase 14):
- [ ] Push any unpushed roborev fix commits
- [ ] Review top-5 open high-severity findings
- [ ] Run `roborev refine` on today's commits at session end
- [ ] Record recurring patterns in `knowledge/LOG.md`
