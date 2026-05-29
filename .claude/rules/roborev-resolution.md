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

## Composite Priority Scorer (Component 2, JohnGavin/llm#163)

`roborev_project_backlog.sh` scores each open finding using:

```
priority = severity_weight × category_risk × (1 + log10(days_old)) × (1 + log10(file_touches_30d))
```

Weights: `severity_weight` — Critical=10, High=5, Medium=2, Low=1. `category_risk` — security=3, error-handling=2.5, async=2, dependency/test=1.5, performance=1.2, other=1, docs=0.5. `file_touches_30d` counts git commits touching that file in the last 30 days (defaults to 1 when the file path cannot be identified). The backlog table is sorted by `priority DESC`; `age_days` is retained as a transparency column.

At session start, `session_init.sh` Phase 13d emits a one-line banner:

```
roborev-backlog: open=N (priority-1=sev:cat, top=#id) | addressed=XX%
```

The banner is silent when `.roborev/reviews.db` is absent (portability — CI, other machines).

## Per-Session Workflow (Mandatory)

### Session Start (session_init.sh Phase 13d)

1. Read the `roborev-backlog:` banner in session-init output — it shows open count, top finding, and addressed rate.
2. Check `.roborev/backlog.md` for the full prioritised list before starting fixes.
3. Report unpushed roborev fix commits: `git log origin/main..HEAD --oneline | grep "Address review findings"`
4. Report open high-severity findings: `roborev fix --list --min-severity high | head -5`
5. Push any unpushed roborev fixes

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

## Commit Convention (Component 3)

When a commit addresses a roborev finding, include a citation in the commit message body
using one of these three patterns (case-insensitive):

```
fixes roborev #N          — fix applied; ID must be open in the DB
closes roborev #N         — finding resolved another way; ID must be open
wontfix roborev #N [reason: <explanation>]  — intentional non-fix; requires a reason tag
```

Variants also accepted: `fix`, `close` (no trailing s); `roborev#N` (no space before #).

The pre-commit hook (`git-hooks/commit-msg` → `roborev_citation_validate.sh`) validates
each cited ID against `~/.roborev/reviews.db`:

- Cited ID not found → commit blocked (exit 1)
- Cited ID already closed → commit blocked (exit 1)
- DB unavailable → hook passes (fail-open; offline commits are never blocked)

**Bypass (emergency):** `git commit --no-verify` skips all hooks including this one.

**Refs vs Closes:** Use `Refs #N` (GitHub issue syntax, no `roborev`) to cross-reference
related issues without triggering the validator. The validator only acts on the
`roborev #N` prefix.

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

### Rollout: SKIP defaulted ON (7-day soak) — COMPLETE

The 7-day soak ran from 2026-05-20 (PR #196 merged) to 2026-05-27. During the soak, `session_stop.sh` invoked `session_end_refine.sh` with `SKIP_SESSION_END_REFINE=1` prefixed so each call exited early with `result=skipped`. The log confirmed:

- `session_init.sh` Phase 14 wrote the start-SHA file correctly
- `session_stop.sh` fired the script at each `/bye`
- cwd-detection and project-name sanitisation found the right project
- Nothing in `/bye` became noticeably slower

The `SKIP_SESSION_END_REFINE=1` prefix was removed in PR #202 (merged 2026-05-27). The refine now runs by default at every `/bye`. The opt-out env var remains available per-session.

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

## Poller Schedule Decision (2026-05-23, #217)

### What changed

`com.claude.roborev-poll-merges.plist` was updated from:

```
StartInterval: 900   (every 15 min, 24/7)
```

to:

```
StartCalendarInterval: hourly, Mon–Fri 09:00–22:00 (70 fire points per week)
```

### Why business hours

Issue #217 diagnosed the poller log showing repeated `behind=0 enqueued=0` runs
during overnight and weekend hours — no PRs are merged outside working hours in
this solo development context, so every off-hours fire is a no-op that burns
launchd overhead and pollutes the log.

The 15-minute interval was originally chosen for responsiveness during active
development. Hourly during business hours gives adequate latency (at most 1h
delay before a newly-merged PR is reviewed) while eliminating ~90% of no-op
fire events.

### Reload instructions (after merge to main)

```bash
# Unload old plist
launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.claude.roborev-poll-merges.plist

# Copy updated plist
cp /Users/johngavin/docs_gh/llm/.claude/launchd/com.claude.roborev-poll-merges.plist \
   ~/Library/LaunchAgents/com.claude.roborev-poll-merges.plist

# Load new schedule
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.claude.roborev-poll-merges.plist

# Verify
launchctl print "gui/$(id -u)/com.claude.roborev-poll-merges" | grep -A2 calendar
```

### Ephemeral-repos cleanup

The poller reported `total=55` repos because roborev's `repos` table accumulates
every path that was ever passed to `roborev review`, including ephemeral
`/private/tmp/` worktree checkouts from agent runs. These entries contribute
noise to the poller's per-repo scan loop.

Cleanup script: `~/.claude/scripts/cleanup_ephemeral_repos.sql`

To execute (operator step, after reviewing the TO DELETE preview):

```bash
sqlite3 ~/.roborev/reviews.db < ~/.claude/scripts/cleanup_ephemeral_repos.sql
```

The script is idempotent and wrapped in a transaction. It shows a dry-run
preview, deletes matching rows, and then prints surviving entries for
confirmation.

### Future path: Option B (post-merge hook)

The poller exists only to cover remote-merged PRs that don't fire the local
`post-commit` hook. A proper fix is a server-side or CI post-merge hook that
calls `roborev review` immediately when GitHub merges a PR. Once that is in
place, the poller becomes redundant and should be unloaded and removed.

Tracked in #217.

## Auto-Verifier (Component 4, JohnGavin/llm#163 Slice 3)

### What it does

When a commit message contains a `closes/fixes roborev #N` citation (validated by
the Component 3 commit-msg hook), the auto-verifier:

1. Parses cited finding IDs.
2. Triggers a roborev re-review of the commit.
3. Polls until the re-review completes (max 120 seconds).
4. On **approval** → writes a row to `closures` table + calls `roborev close <id>`.
5. On **rejection** → writes a row to `fix_rejected_queue` for human triage.
6. On any failure (binary absent, DB unavailable, poll timeout) → exits 0 (**fail-open**).

### Opt-in semantics

The verifier is **NOT auto-installed**. To install:

```bash
# 1. Apply DB migration (one-time per machine)
sqlite3 ~/.roborev/reviews.db < ~/.claude/scripts/roborev_schema_migration_v2.sql

# 2. Dry-run to preview the hook content
bash ~/.claude/scripts/roborev_install_auto_verify_hook.sh --repo <path> --dry-run

# 3. Install (creates .git/hooks/post-commit → roborev_auto_verify.sh --apply)
bash ~/.claude/scripts/roborev_install_auto_verify_hook.sh --repo <path>
```

To uninstall: `bash ~/.claude/scripts/roborev_install_auto_verify_hook.sh --repo <path> --uninstall`

### Pilot target: t_demos

Pilot on `t_demos` only until ≥3 auto-closures, 0 wrong-closures. Expand to other
projects after pilot passes. Never expand to a project with open Critical findings
until the human-gate guardrail ships (Slice 4 / Component 7).

### DB schema (migration_v2)

Two new tables added to `~/.roborev/reviews.db` by `roborev_schema_migration_v2.sql`:

| Table | Purpose |
|---|---|
| `closures` | Audit log of auto-close decisions (type: approved / wontfix / manual / stale) |
| `fix_rejected_queue` | Fix commits that roborev re-reviewed and rejected; requires human triage |

Migration is idempotent (`CREATE TABLE IF NOT EXISTS`). Safe to re-run.

### Triage query (pending rejections)

```sql
SELECT id, finding_ids_json, fix_commit_sha, rejection_summary, attempted_at
FROM fix_rejected_queue
WHERE resolved = 0
ORDER BY attempted_at DESC
LIMIT 20;
```

### Kill switch

```bash
# Disable for one commit
SKIP_ROBOREV_VALIDATOR=1 git commit ...

# Uninstall from a project
bash ~/.claude/scripts/roborev_install_auto_verify_hook.sh --repo <path> --uninstall

# Reopen a wrongly closed finding
roborev reopen <finding_id>
```

### Log

`~/.claude/logs/roborev_auto_verify.log` — one entry per verifier run.

## Merge Gate (dry-run mode)

Tracked in llm#241. MVP ships the dry-run script only — enforcement deferred.

### What it does

`~/.claude/scripts/roborev_merge_gate.sh <pr#>` queries `~/.roborev/reviews.db` for
open findings whose `commit_sha` is in the PR's commits, then checks whether each
finding has been cited in a commit message (`closes/fixes/acks roborev #N`) or
explicitly acked via `roborev_ack.sh`.

### Verdicts

| Verdict | Meaning | Mode |
|---------|---------|------|
| `[gate-pass]` | 0 unresolved findings at threshold | always exits 0 |
| `[gate-warn]` | Medium-only unresolved findings | exits 0, week-1 signal |
| `[gate-block]` | High/Critical unresolved findings | dry-run: exits 0, enforce: exits 1 |

### Invoking the gate

```bash
# Dry-run (default) — always exits 0, prints verdict
~/.claude/scripts/roborev_merge_gate.sh 253

# Explicit dry-run
~/.claude/scripts/roborev_merge_gate.sh --dry-run 253

# From branch name (auto-detects PR#)
~/.claude/scripts/roborev_merge_gate.sh --branch feat/my-feature

# Enforce mode (NOT active yet — for future CI integration)
~/.claude/scripts/roborev_merge_gate.sh --enforce 253
```

Logs to `~/.claude/logs/merge_gate.log` (one JSON line per invocation).

### Ack flow for false positives

When a finding is a confirmed false positive or wontfix, use the ack CLI:

```bash
# Dry-run (default) — shows what would be written, prints commit guidance
~/.claude/scripts/roborev_ack.sh 42 --reason "false positive — nix-only path" --pr 253

# Apply (writes to ~/.roborev/acks.jsonl)
~/.claude/scripts/roborev_ack.sh 42 --reason "false positive — nix-only path" --pr 253 --apply
```

Then include the printed line in your commit message:
```
acks roborev #42 --reason "false positive — nix-only path"
```

The ack does NOT close the finding in `reviews.db`. Closure happens via fix-commit +
auto-verifier (#163) or manual `roborev close`.

### Week-1 data plan

For the first week, run the gate on every PR before merge and let it log to
`~/.claude/logs/merge_gate.log`. After 1 week:

1. Review `merge_gate.log` — how many gate-block / gate-warn verdicts?
2. File a follow-up issue with the enforce-mode decision.
3. If High/Critical block rate is low, enable `--enforce` for High/Critical only.
4. Update the PR template to make the checklist row mandatory.

### Threshold

Reads `review_min_severity` from per-repo `.roborev.toml` (default `medium`).
The gate currently warns on Medium and would block on High/Critical in enforce mode.

### Interaction with severity-autoclose (#224)

Autoclose operates on **aged** findings (>7d). The gate operates on **PR-current**
findings (any age on the PR's commits). The two do not cancel each other: a finding
autoclosed for age satisfaction is `closed=1` and therefore invisible to the gate.

### Kill switch

Set `SKIP_MERGE_GATE=1` in your shell environment to bypass the gate in dry-run mode
(the gate script exits 0 immediately). For enforce mode the kill switch is simply
not invoking `--enforce`.

## Related

- `auto-delegation` — model selection for Claude Code agents (separate from roborev agents)
- `btw-timeouts` — MCP tool timeout pattern (similar "bounded execution" principle)
- `orchestrator-protocol` — background agent timeout protocol
- llm#110 — tracking issue
- llm#241 — merge gate policy (Merge Gate section above)
- llm#163 — closure-loop automation (Auto-Verifier section above — Component 4, Slice 3)
- llm#224 — severity autoclose (sibling policy)
- llm#217 — poller schedule + ephemeral-repos cleanup
- llm#300 — weekly launchd health email (long-term solution)

## launchd Job Health — Immediate Audit

If roborev or other automated jobs appear to have stopped running (e.g. autoclose log is
days stale, backlog is not updating), run the ad-hoc audit script to see which plists
are installed but NOT loaded by launchd:

```bash
bin/launchd_health_audit.sh --quiet
```

Output sections:
- **Section 3** (NOT loaded) — jobs with plists installed but not loaded; these will never fire.
  Fix with: `launchctl load -w ~/Library/LaunchAgents/<label>.plist`
- **Section 2** (Loaded, failing) — jobs loaded but last exit code was non-zero.
- **Section 4** (Stale) — jobs loaded but haven't fired within 1.5× their cadence.

Common trigger: after a macOS update or logout/login cycle, launchd may unload all user
agents. Use `bin/launchd_health_audit.sh` to confirm, then reload the affected plists.

The weekly health email (llm#300) will automate this check once its `launchd_runs`
ledger is populated. Until then, run `bin/launchd_health_audit.sh` any time a roborev
job looks stale.
