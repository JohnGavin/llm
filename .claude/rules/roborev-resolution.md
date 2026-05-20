---
paths: ["**/.roborev.toml", ".git/hooks/post-commit"]
---

# Rule: roborev Resolution Workflow

## Source

JohnGavin/llm#110. First run 2026-05-07 on historical project: 91 failed reviews, 0% resolution rate. After one session: 4 addressed, 40% weekly resolution rate. Codex agent confirmed working after PATH fix.

## When This Applies

Every project with roborev post-commit hook enabled (`roborev install-hook`).

## CRITICAL: roborev Findings Accumulate Unless Explicitly Resolved

roborev reviews every commit automatically. Findings persist in its database until explicitly closed via `roborev fix`, `roborev refine`, or `roborev close`. A 0% resolution rate means technical debt grows with every commit.

## Per-Session Workflow (Mandatory)

### Session Start (session_init.sh Phase 14)

1. Report unpushed roborev fix commits: `git log origin/main..HEAD --oneline | grep "Address review findings"`
2. Report open high-severity findings: `roborev fix --list --min-severity high | head -5`
3. Push any unpushed roborev fixes

### During Session

When touching a file with open roborev findings, fix them in the same commit. Don't create new debt on files with existing debt.

### Session End

Run one bounded refine cycle on today's commits:
```bash
roborev refine --agent codex --min-severity high --max-iterations 3 --since <first-commit-today>
```
Push any fixes: `git push`

## Agent Fallback Chain

```
codex (cheapest) → gemini (free tier) → claude-code (most expensive, last resort)
```

Config in `~/.roborev/config.toml`:
```toml
default_agent = 'codex'
default_backup_agent = 'gemini'
codex_cmd = '/usr/local/bin/codex'    # npx wrapper (nix strips /usr/local/bin)
```

When codex hits rate limit: re-run with `--agent gemini`. roborev does not auto-fallback on rate limits.

## Backlog Burn-Down (One-Time per Project)

For projects with large backlogs (>20 open reviews):
```bash
roborev refine --agent codex --min-severity high --max-iterations 10 --since <earliest-commit> --quiet
```

Run in a separate terminal. If codex limit exhausted:
```bash
roborev refine --agent gemini --min-severity high --max-iterations 10 --since <earliest-commit> --quiet
```

Push when done: `git push`

## Per-Project Config

Every project with roborev must have `.roborev.toml`:
```toml
fix_min_severity = "high"
refine_min_severity = "high"
max_prompt_size = 200000
```

## What roborev Does and Does NOT Do

| Action | Automatic? |
|--------|:---:|
| Review every commit | Yes (post-commit hook) |
| Find issues by severity | Yes |
| Fix code (via agent) | Yes (creates commits in worktree) |
| Re-review fixes | Yes (refine loop) |
| Push to remote | **No — manual** |
| Run tests / R CMD check | **No — separate step** |
| Retry after token exhaustion | **No — manual re-run** |
| Warn when agent unavailable | **No — silently falls back** |

## Severity Filtering

| Severity | When to fix | roborev flag |
|----------|-------------|-------------|
| Critical | Immediately | `--min-severity critical` |
| High | Same session | `--min-severity high` (default) |
| Medium | When touching same file | `--min-severity medium` |
| Low | Tech debt session only | `--min-severity low` |

## "Agent Made No Changes — Skipping"

This means the agent couldn't figure out what to change. The review stays open. Options:
1. Try smarter agent: `roborev fix <job-id> --agent claude-code`
2. Fix manually
3. Close if stale: `roborev close <job-id>`

## Documenting Findings

| Layer | Where | What |
|-------|-------|------|
| Per-commit | roborev DB | Raw findings (automatic) |
| Per-project | `project/knowledge/LOG.md` | High-severity findings + resolution |
| Cross-project | `llm/knowledge/wiki/roborev-patterns.md` | Recurring patterns → rule candidates |
| Global rules | `llm/.claude/rules/` | Graduated patterns (3+ occurrences) |

## Coverage Model (CRITICAL — what roborev does NOT catch)

### Lesson 2026-05-13: remote-merged PRs don't fire post-commit

`post-commit` only fires on **local** `git commit`. PRs merged on GitHub (web UI, `gh pr merge`, auto-merge) reach the repo via `git fetch` / `git pull` / `git merge --ff` — **none of these trigger `post-commit`**. Projects that do most work via PRs therefore have near-zero roborev coverage despite the hook being installed.

Symptom: roborev DB shows no jobs for a repo for hours/days despite commits being on `origin/main`.

Diagnosis: compare `git log -1 --pretty=%H` with the latest reviewed commit_sha in `~/.roborev/reviews.db` for that repo. If git is ahead → PR merges are uncovered.

Backfill: `(cd <repo> && roborev review --since <last_reviewed_sha>)`.

Long-term fix: a periodic poller (tracked in #148) that fetches each watched repo and runs `roborev review --since` if HEAD is ahead. The post-commit hook alone is insufficient.

## Known Issues

- **Remote-merged PRs invisible** (see above) — install local hook + periodic `--since` poll
- `codex` and `gemini` not in nix shell PATH — wrappers at `/usr/local/bin/` + `codex_cmd` config
- `--agent codex` silently falls back to claude-code if codex unavailable (no error)
- `check-agents` uses PATH lookup, but actual commands use `*_cmd` config
- No `gemini_cmd` config key exists yet
- `core.hooksPath` shared across repos (e.g., `llm/git-hooks/`) — `roborev install-hook` writes to the shared path, so one install covers many repos but a misconfigured one breaks many at once
- **`.roborev.toml` is gitignored in some projects** (e.g., micromort line 52) but tracked in others (coMMpass, llm). Edits in gitignored projects are LOCAL-only and silently disappear if `roborev init` regenerates. Check `git check-ignore .roborev.toml` before editing; if ignored, add a top-of-file comment recording the manual value (since the comment is the only durable signal that survives regeneration in the file's own context).

## Session-End Refine (Automated)

The session-end refine runs automatically when the user types `/bye`.

### Rollout: SKIP defaulted ON (7-day soak)

For the first 7 days after deployment, `session_stop.sh` invokes `session_end_refine.sh` with `SKIP_SESSION_END_REFINE=1` prefixed, so each call exits early with `result=skipped` and only the bookkeeping logs are written. This lets us observe:

- That `session_init.sh` Phase 14 wrote the start-SHA file
- That `session_stop.sh` actually fires the script at /bye
- That the cwd-detection / project-name sanitisation logic finds the right project
- That nothing else in `/bye` got slower

After 7 clean days, **remove the `SKIP_SESSION_END_REFINE=1` prefix from session_stop.sh** in a follow-up commit. The opt-out env var remains available per-session (set in shell rc files or one-off).

### What runs

`~/.claude/scripts/session_end_refine.sh` is invoked by `session_stop.sh` in the background via `nohup`. It reads the session-start SHA recorded by `session_init.sh` (Phase 14) and calls:

```bash
timeout 120 roborev refine \
  --since <session-start-sha> \
  --max-iterations 3 \
  --min-severity high \
  --quiet \
  --agent codex
```

### Bounds

| Bound | Value | Effect |
|-------|-------|--------|
| `timeout 120` | 2 minutes | Hard wall-clock kill |
| `--max-iterations 3` | 3 iterations | roborev internal cap |
| `--min-severity high` | High+ only | Skips low/medium noise |
| `nohup ... &` | Background | Never blocks `/bye` |

### Opt-out mechanisms

| Mechanism | How to set | Scope |
|-----------|------------|-------|
| Env var | `SKIP_SESSION_END_REFINE=1` before `/bye` | Session-level |
| TOML flag | `session_end_refine = false` in `.roborev.toml` | Per-project |

### Log location

`~/.claude/logs/session_end_refine.log` — one line per session:
```
2026-05-20 14:32:01 project=llm start-sha=abc1234 result=ok
```

Result values: `ok`, `timeout`, `error`, `skipped`.

### State file

`~/.claude/.session_start_sha_<sanitized-project-name>` — written by `session_init.sh` Phase 14 at session start.

## Related

- `auto-delegation` — model selection for Claude Code agents (separate from roborev agents)
- `btw-timeouts` — MCP tool timeout pattern (similar "bounded execution" principle)
- `orchestrator-protocol` — background agent timeout protocol
- llm#110 — tracking issue
