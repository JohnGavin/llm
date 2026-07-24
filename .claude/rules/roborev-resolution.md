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

`post-commit` only fires on **local** `git commit`. PRs merged on GitHub (web UI, `gh pr merge`, auto-merge) reach the repo via `git fetch` / `git pull` / `git merge --ff` — **none of these trigger `post-commit`**. Projects that do most work via PRs therefore have near-zero roborev coverage from the post-commit hook alone.

Diagnosis: compare `git log -1 --pretty=%H` with the latest reviewed `commit_sha` in `~/.roborev/reviews.db` for that repo. If git is ahead → PR merges are uncovered. Backfill: `(cd <repo> && roborev review --since <last_reviewed_sha>)`.

This gap is now closed by the post-merge hook + thrice-daily poller (see "Review Trigger Mechanisms" below). See companion for the original 2026-05-13 diagnosis narrative.

## Known Issues

- **Remote-merged PRs invisible** to the post-commit hook alone (see "Coverage Model" above) — install local hook + periodic `--since` poll
- **`.roborev.toml` is gitignored in some projects** (e.g., micromort) but tracked in others (coMMpass, llm). Edits in gitignored projects are LOCAL-only and silently disappear if `roborev init` regenerates. Check `git check-ignore .roborev.toml` before editing; if ignored, add a top-of-file comment recording the manual value.

More edge cases (PATH/wrapper quirks, `hooksPath` sharing, silent agent fallback) are in the companion doc.

## Session-End Refine (Automated)

Runs automatically at `/bye`. Rollout completed (7-day soak, PRs #196/#202) — see companion for the soak history.

### What runs

`~/.claude/scripts/session_end_refine.sh`, invoked by `session_stop.sh` in the background via `nohup`, reads the session-start SHA (written by `session_init.sh` Phase 14 to `~/.claude/.session_start_sha_<sanitized-project-name>`) and calls:

```bash
timeout 120 roborev refine --since <session-start-sha> --max-iterations 3 --min-severity high --quiet --agent codex
```

### Bounds and opt-out

| Bound / Mechanism | Value | Effect / Scope |
|-------|-------|--------|
| `timeout 120` | 2 minutes | Hard wall-clock kill |
| `--max-iterations 3` | 3 iterations | roborev internal cap |
| `--min-severity high` | High+ only | Skips low/medium noise |
| `nohup ... &` | Background | Never blocks `/bye` |
| Env var `SKIP_SESSION_END_REFINE=1` | Set before `/bye` | Session-level opt-out |
| TOML flag `session_end_refine = false` | In `.roborev.toml` | Per-project opt-out |

Logs to `~/.claude/logs/session_end_refine.log` (one line per session; result values `ok`, `timeout`, `error`, `skipped`).

## Review Trigger Mechanisms (Phase 1.7, #217)

### Coverage model — three-tier

| Tier | Trigger | Fires on | Introduced |
|------|---------|----------|------------|
| Primary | `post-commit` git hook | Every local `git commit` | Phase 1.0 |
| Secondary | `post-merge` git hook | Every `git pull` / `git merge --ff` that changes HEAD | Phase 1.7 (#217) |
| Safety net | launchd poller (thrice-daily) | Cron: Mon–Fri 09:00, 13:00, 17:00 | Phase 1.7 (#217) |

The post-merge hook fills the primary gap: remote-merged PRs that arrive via
`git pull` trigger `post-commit` on the local checkout but NOT on the server.
The thrice-daily poller is the last-resort backstop for repos that haven't yet
had the post-merge hook installed, or for any merge path that bypasses both
hooks (e.g. direct SHA pushes, force-pushes, `git reset --hard`).

Phase 4 (full poller removal) is deferred until the hook rollout has had a
7-day soak across all watched repos. Install steps, ephemeral-repos cleanup,
and the full poller-schedule decision history are in the companion doc.

## Auto-Verifier (Component 4, JohnGavin/llm#163 Slice 3)

When a commit message cites `closes/fixes roborev #N` (validated by the Component 3
commit-msg hook), the auto-verifier triggers a re-review of the commit, polls until it
completes (max 120s), and on **approval** writes to the `closures` table + calls
`roborev close <id>`; on **rejection** writes to `fix_rejected_queue` for human triage;
on any failure (binary absent, DB unavailable, poll timeout) exits 0 (**fail-open**).

The verifier is **NOT auto-installed** — see companion for install/uninstall steps,
the `t_demos` pilot scope, and the triage query.

### DB schema (migration_v2)

Two new tables added to `~/.roborev/reviews.db` by `roborev_schema_migration_v2.sql`
(idempotent, `CREATE TABLE IF NOT EXISTS`):

| Table | Purpose |
|---|---|
| `closures` | Audit log of auto-close decisions (type: approved / wontfix / manual / stale) |
| `fix_rejected_queue` | Fix commits that roborev re-reviewed and rejected; requires human triage |

### Kill switch

`SKIP_ROBOREV_VALIDATOR=1 git commit ...` disables for one commit. Uninstall via
`roborev_install_auto_verify_hook.sh --repo <path> --uninstall`. Reopen a wrongly
closed finding with `roborev reopen <finding_id>`. Log: `~/.claude/logs/roborev_auto_verify.log`.

## Merge Gate (dry-run mode)

Tracked in llm#241. MVP ships the dry-run script only — enforcement deferred.
`~/.claude/scripts/roborev_merge_gate.sh <pr#>` queries `~/.roborev/reviews.db` for
open findings whose `commit_sha` is in the PR's commits, then checks whether each
finding has been cited (`closes/fixes/acks roborev #N`) or explicitly acked via
`roborev_ack.sh`. Usage examples and the ack-flow CLI are in the companion doc.

### Verdicts

| Verdict | Meaning | Mode |
|---------|---------|------|
| `[gate-pass]` | 0 unresolved findings at threshold | always exits 0 |
| `[gate-warn]` | Medium-only unresolved findings | exits 0, week-1 signal |
| `[gate-block]` | High/Critical unresolved findings | dry-run: exits 0, enforce: exits 1 |

Reads `review_min_severity` from `.roborev.toml` (default `medium`). Logs to
`~/.claude/logs/merge_gate.log` (one JSON line per invocation).

### Interaction with severity-autoclose (#224)

Autoclose operates on **aged** findings (>7d). The gate operates on **PR-current**
findings (any age on the PR's commits). The two do not cancel each other: a finding
autoclosed for age satisfaction is `closed=1` and therefore invisible to the gate.

### Kill switch

`SKIP_MERGE_GATE=1` bypasses the gate in dry-run mode (exits 0 immediately). For
enforce mode, the kill switch is simply not invoking `--enforce`.

## Merge-gate policy (#241, pilot HIGH)

> No PR merges to `main` while any related roborev finding at severity ≥ `review_min_severity`
> (currently `High` in the pilot) is `closed=0` AND not cited by a `closes roborev #N`
> (or `acks roborev #N --reason …`) line in the PR's commits.

### Definitions

| Term | Meaning |
|------|---------|
| **Related** | A roborev review whose `commit_sha` is in `git log origin/main..<head>` (commit-scope, Alternative C from #241 — tightest scope, avoids day-1 backlog freeze) |
| **Resolved** | `closed=1` in `~/.roborev/reviews.db` AND has a commit message citing it — OR — an explicit `acks roborev #N --reason "…"` commit |
| **Threshold** | Pilot: `High` (enforced by `bin/roborev_merge_gate.sh`). Per-repo override via `.roborev.toml` `review_min_severity` in Phase 3. |
| **Acked** | Waiver written to `~/.roborev/acks.jsonl` via `roborev_ack.sh --apply` with a written reason. Does NOT close the finding; closure is via fix-commit + auto-verifier (#163). |

### Pilot escalation path

1. **Pilot (now):** `bin/roborev_merge_gate.sh` enforces HIGH only. Run before every merge.
2. **After 1 week of signal:** review `~/.claude/logs/merge_gate.log`. If block rate is low, escalate threshold to MEDIUM.
3. **Phase 3 (per-repo):** read threshold from `.roborev.toml` `review_min_severity` instead of hardcoded High.

Exit codes: `0` = PASS (no unresolved findings), `1` = BLOCK (unresolved findings found).
The `bin/` script enforces; the predecessor `~/.claude/scripts/roborev_merge_gate.sh` is
dry-run only (always exits 0), kept for week-1 signal logging. Local invocation examples
are in the companion doc.

## Related

- [`_companions/roborev-resolution-details.md`](_companions/roborev-resolution-details.md) — incident log, rollout history, one-time procedures, verbose CLI usage split out of this rule
- `auto-delegation` — model selection for Claude Code agents (separate from roborev agents)
- `btw-timeouts` — MCP tool timeout pattern (similar "bounded execution" principle)
- `orchestrator-protocol` — background agent timeout protocol
- llm#110 — tracking issue
- llm#241 — merge gate policy (Merge Gate sections above)
- llm#163 — closure-loop automation (Auto-Verifier section above — Component 4, Slice 3)
- llm#224 — severity autoclose (sibling policy)
- llm#217 — poller schedule + ephemeral-repos cleanup
- llm#300 — weekly launchd health email (long-term solution)

## launchd Job Health — Immediate Audit

If roborev or other automated jobs appear to have stopped running (e.g. autoclose log
is days stale, backlog is not updating), run `bin/launchd_health_audit.sh --quiet` — it
reports plists installed-but-not-loaded, loaded-but-failing, and stale jobs. Full
output-section breakdown and the weekly-health-email follow-up (llm#300) are in the
companion doc.
