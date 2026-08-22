---
paths: ["**/.roborev.toml", ".git/hooks/post-commit"]
---

# Rule: roborev Resolution Workflow

## Source and Scope

JohnGavin/llm#110. First run 2026-05-07 on historical project: 91 failed reviews, 0% resolution rate. After one session: 4 addressed, 40% weekly resolution rate. Codex agent confirmed working after PATH fix. Applies to every project with roborev post-commit hook enabled (`roborev install-hook`).

## CRITICAL: roborev Findings Accumulate Unless Explicitly Resolved

roborev reviews every commit automatically. Findings persist in its database until explicitly closed via `roborev fix`, `roborev refine`, or `roborev close`. A 0% resolution rate means technical debt grows with every commit.

## Composite Priority Scorer (Component 2, JohnGavin/llm#163)

`roborev_project_backlog.sh` scores each open finding using:

```
priority = severity_weight × category_risk × (1 + log10(days_old)) × (1 + log10(file_touches_30d))
```

Full weight tables (severity/category) are in the companion doc. The backlog table is sorted by `priority DESC`; `age_days` is retained as a transparency column. At session start, `session_init.sh` Phase 13d emits a `roborev-backlog:` banner (silent when `.roborev/reviews.db` is absent — portability for CI/other machines).

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

One-time backlog burn-down for projects with >20 open reviews: see companion.

## Per-Project Config

Every project with roborev must have `.roborev.toml`:
```toml
fix_min_severity = "high"
refine_min_severity = "high"
max_prompt_size = 200000
```

## Severity Filtering

| Severity | When to fix | roborev flag |
|----------|-------------|-------------|
| Critical | Immediately | `--min-severity critical` |
| High | Same session | `--min-severity high` (default) |
| Medium | When touching same file | `--min-severity medium` |
| Low | Tech debt session only | `--min-severity low` |

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

`post-commit` only fires on **local** `git commit`. PRs merged on GitHub (web UI, `gh pr merge`, auto-merge) reach the repo via `git fetch` / `git pull` / `git merge --ff` — **none of these trigger `post-commit`**. Projects that do most work via PRs therefore have near-zero roborev coverage from the post-commit hook alone.

Diagnosis: compare `git log -1 --pretty=%H` with the latest reviewed `commit_sha` in `~/.roborev/reviews.db` for that repo. If git is ahead → PR merges are uncovered. Backfill: `(cd <repo> && roborev review --since <last_reviewed_sha>)`.

This gap is now closed by the post-merge hook + thrice-daily poller (see "Review Trigger Mechanisms" in the companion). See companion for the original 2026-05-13 diagnosis narrative.

## Requeue Dropped Quota Failures (llm#927)

Once `retry_count` exhausts its cap, `status='failed'` is TERMINAL — nothing revisits the commit after the agent's quota resets, and `roborev_poll_merges.sh` only looks for unreviewed commits, not failed jobs to retry. `.claude/scripts/roborev_requeue_dropped.sh` finds terminally failed rows whose `error` matches a verified quota/spend pattern and whose commit has no successful review or job in flight, and re-enqueues up to `--limit` (default 5) via `roborev review --sha <sha> --repo <root_path>`.

**The exclude_patterns trap:** a candidate touching ONLY paths excluded by its own repo's `.roborev.toml` (see `roborev-exclude-patterns`) is skipped, not enqueued — otherwise the sweep re-automates exactly the noise `exclude_patterns` exists to remove.

```bash
.claude/scripts/roborev_requeue_dropped.sh                 # dry-run (default), --limit=5
.claude/scripts/roborev_requeue_dropped.sh --apply --limit=3
.claude/scripts/roborev_requeue_dropped.sh --selftest       # fixture-based suite
```

Wired into `com.claude.roborev-poll-merges` (thrice daily, Mon–Fri 09:00/13:00/17:00); fail-open, `timeout 120`, opt out with `SKIP_ROBOREV_REQUEUE=1`. Measured results and scheduling rationale: incidents companion.

## Known Issues (more edge cases — PATH/wrapper quirks, `hooksPath` sharing, gitignored `.roborev.toml`, silent agent fallback — in the companion)

- **Remote-merged PRs invisible** to the post-commit hook alone (see "Coverage Model" above) — install local hook + periodic `--since` poll
- **`"parse error: no valid stream-json"` is a FABRICATED cause, not a real diagnosis (llm#954).** roborev is a compiled third-party binary we cannot patch. An agent process exiting non-zero with empty stdout produces this message, which describes roborev's *own* parsing step, not the agent's actual failure — the real cause (expired key, network failure, quota) is discarded and never logged. **Run the agent's exact command manually and read stderr** to find the real cause. Full diagnosis procedure + detection query in the companion.

## Related

- [`_companions/roborev-resolution-details.md`](_companions/roborev-resolution-details.md) — verbose CLI usage, the automation-does/does-not table, session-end refine bounds, review trigger tiers, auto-verifier, merge-gate policy, and the launchd health audit, split out of this rule
- [`_companions/roborev-resolution-incidents.md`](_companions/roborev-resolution-incidents.md) — dated incident narratives and one-time rollout history (poller schedule decision, session-end-refine soak, remote-merged-PR coverage-gap lesson), split out of the details companion
- `roborev-exclude-patterns` — the exclude_patterns config `roborev_requeue_dropped.sh` reads before enqueueing; its llmtelemetry case study is the trap that script's filtering exists to respect
- `housekeeping-framework` — the hk_run_start/hk_run_end heartbeat pattern `roborev_requeue_dropped.sh` follows, and the "check for an existing slot before adding a plist" discipline behind its scheduling recommendation
- `auto-delegation` — model selection for Claude Code agents (separate from roborev agents)
- `btw-timeouts` — MCP tool timeout pattern (similar "bounded execution" principle)
- `orchestrator-protocol` — background agent timeout protocol
- llm#110 — tracking issue
- llm#241 — merge gate policy (Merge Gate sections in the companion)
- llm#163 — closure-loop automation (Auto-Verifier section in the companion — Component 4, Slice 3)
- llm#927 — quota failures are terminal; `roborev_requeue_dropped.sh` origin issue
- llm#224 — severity autoclose (sibling policy)
- llm#217 — poller schedule + ephemeral-repos cleanup
- llm#300 — weekly launchd health email (long-term solution); see companion for the launchd health audit procedure
