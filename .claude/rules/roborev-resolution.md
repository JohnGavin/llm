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

## Eval Harness — Regression Check on Agent Swap (llm#1044)

roborev is a third-party closed-source binary we cannot patch, and we have no automated evaluation of its review *quality* — only that a job ran (gemini-2.5-flash-lite silently failed to read the diff on 15.5% of its reviews in this repo before anyone noticed; llm#1035). **After changing `.roborev.toml` `agent=`/`model=` (globally or per-repo), run the eval harness before trusting the new config in production:**

```bash
.claude/scripts/roborev_eval_run.sh --agent <new-agent> --model <new-model>
.claude/scripts/roborev_eval_run.sh --selftest   # classification-logic-only, no live call
```

The harness replays 5 golden diffs through a live review and classifies each `PASS`/`FAIL`/`ERROR`/`TIMEOUT` — an `ERROR` is never folded into a pass, per `checks-must-distinguish-unknown`. Documentation-as-gate, not an automated hook — a human runs this manually before trusting a config change. Full origin narrative: companion doc.

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

When a commit addresses a roborev finding, include a citation in the commit message body using one of these three patterns (case-insensitive; `fix`/`close` singular and `roborev#N` no-space also accepted):

```
fixes roborev #N          — fix applied; ID must be open in the DB
closes roborev #N         — finding resolved another way; ID must be open
wontfix roborev #N [reason: <explanation>]  — intentional non-fix; requires a reason tag
```

The pre-commit hook (`git-hooks/commit-msg` → `roborev_citation_validate.sh`) validates each cited ID against `~/.roborev/reviews.db`: cited ID not found or already closed → commit blocked (exit 1); DB unavailable → hook passes (fail-open; offline commits are never blocked). **Bypass (emergency):** `git commit --no-verify`. Use `Refs #N` (no `roborev`) to cross-reference issues without triggering the validator — it only acts on the `roborev #N` prefix.

## Coverage Model (CRITICAL — what roborev does NOT catch)

`post-commit` only fires on **local** `git commit`. PRs merged on GitHub (web UI, `gh pr merge`, auto-merge) reach the repo via `git fetch` / `git pull` / `git merge --ff` — **none of these trigger `post-commit`**. Projects that do most work via PRs therefore have near-zero roborev coverage from the post-commit hook alone.

Diagnosis: compare `git log -1 --pretty=%H` with the latest reviewed `commit_sha` in `~/.roborev/reviews.db` for that repo. If git is ahead → PR merges are uncovered. Backfill: `(cd <repo> && roborev review --since <last_reviewed_sha>)`.

This gap is now closed by the post-merge hook + thrice-daily poller (see "Review Trigger Mechanisms" in the companion). See companion for the original 2026-05-13 diagnosis narrative.

## Requeue Dropped Quota Failures (llm#927)

roborev retries a job internally, but once `retry_count` exhausts its cap, `status='failed'` is TERMINAL — nothing revisits the commit after the agent's quota resets. `.claude/scripts/roborev_requeue_dropped.sh` finds terminally-failed `review_jobs` rows whose error matches a verified quota/spend pattern and whose commit has no successful review or in-flight job, and re-enqueues up to `--limit` (default 5) of them. Every candidate's changed-file list is checked against its own repo's `.roborev.toml` `exclude_patterns` first — a commit touching only excluded paths is skipped, not enqueued, so the sweep never re-automates the noise `exclude_patterns` exists to remove; an unreliable check (missing checkout, rewritten history) also skips rather than guesses.

```bash
.claude/scripts/roborev_requeue_dropped.sh                 # dry-run (default), --limit=5
.claude/scripts/roborev_requeue_dropped.sh --apply --limit=3
.claude/scripts/roborev_requeue_dropped.sh --selftest       # fixture-based suite
```

Wired into `com.claude.roborev-poll-merges` (fires thrice daily, Mon–Fri 09:00/13:00/17:00) after its primary catchup work, fail-open, bounded by `timeout 120`. Opt out with `SKIP_ROBOREV_REQUEUE=1`. Measured results, the exclude_patterns-trap detail, and heartbeat mechanics: companion doc.

## Known Issues

- **Remote-merged PRs invisible** to the post-commit hook alone (see "Coverage Model" above) — install local hook + periodic `--since` poll
- **`.roborev.toml` is gitignored in some projects** (e.g., micromort) but tracked in others (coMMpass, llm) — edits in gitignored projects are LOCAL-only and silently disappear if `roborev init` regenerates; check `git check-ignore .roborev.toml` before editing
- **`"parse error: no valid stream-json"` is a FABRICATED cause, not a real diagnosis (llm#954)** — it describes roborev's own parsing step, not the agent's actual failure (missing key, network failure, quota exhaustion); diagnose by running the agent's exact command manually and reading stderr, never trust the roborev log line
- **`--agent X` on `roborev compact` does not reliably control every sub-step (llm#411)** — `compact` has ≥3 sub-steps and one can silently invoke a different agent than requested; workaround is to pass `--agent` explicitly and rerun if a sub-step misbehaves, not to debug the precedence further

Full narratives for all four (detection queries, reproduction steps, origin incidents): companion doc. More edge cases (PATH/wrapper quirks, `hooksPath` sharing, silent agent fallback) are also in the companion doc.

## Related

- [`_companions/roborev-resolution-details.md`](_companions/roborev-resolution-details.md) — verbose CLI usage, the automation-does/does-not table, session-end refine bounds, review trigger tiers, auto-verifier, merge-gate policy, launchd health audit
- [`_companions/roborev-resolution-incidents.md`](_companions/roborev-resolution-incidents.md) — dated incident narratives and one-time rollout history (poller schedule decision, session-end-refine soak, coverage-gap lesson, requeue measured results, eval-harness origin, Known Issues full narratives)
- `roborev-exclude-patterns` — the exclude_patterns config `roborev_requeue_dropped.sh` reads before enqueueing (llmtelemetry case study)
- `housekeeping-framework` — the heartbeat pattern `roborev_requeue_dropped.sh` follows, and the "check for an existing slot" scheduling discipline
- `auto-delegation`, `btw-timeouts`, `orchestrator-protocol` — model selection / timeout / background-agent conventions this rule's agent-fallback chain follows
- Tracking issues: llm#110 (this rule), llm#241 (merge gate), llm#163 (auto-verifier), llm#927 (requeue), llm#224 (severity autoclose), llm#217 (poller schedule), llm#1044/#1035 (eval harness), llm#300 (launchd health email)
- `.claude/scripts/roborev_eval_run.sh` / `roborev_eval_classify.py` / `.claude/tests/fixtures/roborev_eval/` — the eval harness itself
