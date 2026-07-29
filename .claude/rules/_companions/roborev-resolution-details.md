# Companion: roborev Resolution — Incident Log, Rollout History, and Verbose How-Tos

Illustrative/historical/verbose-usage detail split out of the always-loaded
[`roborev-resolution`](../roborev-resolution.md) rule to bring it back under
its 300-line hard limit. The **normative** content (CRITICAL statements,
governing decision tables, current bounds/opt-outs, Forbidden Patterns,
Related) stays in the rule; this file is the worked examples, dated incident
narratives, one-time procedures, and verbose CLI usage, loaded on demand.

## Composite Priority Scorer — full weight tables

`roborev_project_backlog.sh` weights: `severity_weight` — Critical=10, High=5,
Medium=2, Low=1. `category_risk` — security=3, error-handling=2.5, async=2,
dependency/test=1.5, performance=1.2, other=1, docs=0.5. `file_touches_30d`
counts git commits touching that file in the last 30 days (defaults to 1 when
the file path cannot be identified).

Banner literal emitted by `session_init.sh` Phase 13d:
```
roborev-backlog: open=N (priority-1=sev:cat, top=#id) | addressed=XX%
```

## "Agent Made No Changes — Skipping"

This means the agent couldn't figure out what to change. The review stays open. Options:
1. Try smarter agent: `roborev fix <job-id> --agent claude-code`
2. Fix manually
3. Close if stale: `roborev close <job-id>`

## Known Issues — additional edge cases

- `codex` and `gemini` not in nix shell PATH — wrappers at `/usr/local/bin/` + `codex_cmd` config
- `--agent codex` silently falls back to claude-code if codex unavailable (no error)
- `check-agents` uses PATH lookup, but actual commands use `*_cmd` config
- No `gemini_cmd` config key exists yet
- `core.hooksPath` shared across repos (e.g., `llm/git-hooks/`) — `roborev install-hook` writes to the shared path, so one install covers many repos but a misconfigured one breaks many at once

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

## Coverage Model — Lesson 2026-05-13: remote-merged PRs don't fire post-commit

`post-commit` only fires on **local** `git commit`. PRs merged on GitHub (web UI, `gh pr merge`, auto-merge) reach the repo via `git fetch` / `git pull` / `git merge --ff` — **none of these trigger `post-commit`**. Projects that do most work via PRs therefore have near-zero roborev coverage despite the hook being installed.

Symptom: roborev DB shows no jobs for a repo for hours/days despite commits being on `origin/main`.

Diagnosis: compare `git log -1 --pretty=%H` with the latest reviewed commit_sha in `~/.roborev/reviews.db` for that repo. If git is ahead → PR merges are uncovered.

Backfill: `(cd <repo> && roborev review --since <last_reviewed_sha>)`.

Long-term fix: a periodic poller (tracked in #148) that fetches each watched repo and runs `roborev review --since` if HEAD is ahead. The post-commit hook alone is insufficient. This gap is now closed by the post-merge hook + thrice-daily poller — see the parent rule's "Review Trigger Mechanisms" section for the current three-tier model.

## Session-End Refine — Rollout: SKIP defaulted ON (7-day soak) — COMPLETE

The 7-day soak ran from 2026-05-20 (PR #196 merged) to 2026-05-27. During the soak, `session_stop.sh` invoked `session_end_refine.sh` with `SKIP_SESSION_END_REFINE=1` prefixed so each call exited early with `result=skipped`. The log confirmed:

- `session_init.sh` Phase 14 wrote the start-SHA file correctly
- `session_stop.sh` fired the script at each `/bye`
- cwd-detection and project-name sanitisation found the right project
- Nothing in `/bye` became noticeably slower

The `SKIP_SESSION_END_REFINE=1` prefix was removed in PR #202 (merged 2026-05-27). The refine now runs by default at every `/bye`. The opt-out env var remains available per-session (see the parent rule's "Opt-out mechanisms" table).

## Installing the post-merge hook per repo

```bash
# Dry-run to preview
bash ~/docs_gh/llm/.claude/scripts/roborev_install_post_merge_hook.sh \
  --repo <path> --dry-run

# Install
bash ~/docs_gh/llm/.claude/scripts/roborev_install_post_merge_hook.sh \
  --repo <path>

# Verify
cat <path>/.git/hooks/post-merge
```

Self-test (validates install + idempotency + fail-open + uninstall):
```bash
CLAUDE_HOOK_SELFTEST=1 bash ~/docs_gh/llm/.claude/scripts/roborev_install_post_merge_hook.sh
```

## Cleaning ephemeral entries from the repos table

```bash
# Preview
roborev_poll_merges.sh --clean-repos-table --dry-run

# Apply
roborev_poll_merges.sh --clean-repos-table
```

Ephemeral entries (root_path starts with `/private/tmp/` or `/tmp/`) are now
also silently skipped during every polling run, so the DB cleanup is optional.

## Poller Schedule Decision (2026-05-23 → 2026-06-01, #217)

### History

| Date | Schedule | Fires/week | Reason for change |
|------|----------|------------|-------------------|
| Initial | Every 15 min, 24/7 | ~672 | First implementation |
| 2026-05-23 | Hourly, Mon–Fri 09:00–22:00 | ~70 | Eliminate overnight no-ops |
| 2026-06-01 | Thrice-daily, Mon–Fri 09:00/13:00/17:00 | 15 | Post-merge hook now provides primary coverage |

### Current schedule

`com.claude.roborev-poll-merges.plist` fires at 09:00, 13:00, and 17:00 on
every weekday (Monday–Friday). 3 fires/day × 5 days = 15 fires/week.

The poller is now the **safety net**, not the primary mechanism. The post-merge
git hook installed per-repo via `roborev_install_post_merge_hook.sh` covers
the pull-time catchup; the poller covers repos without the hook and any
exceptional merge paths.

### Why business hours

Issue #217 diagnosed the poller log showing repeated `behind=0 enqueued=0` runs
during overnight and weekend hours — no PRs are merged outside working hours in
this solo development context, so every off-hours fire is a no-op that burns
launchd overhead and pollutes the log.

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

### Post-merge hook (Phase 1.7, shipped)

The post-merge hook (`roborev_install_post_merge_hook.sh`) was delivered in
Phase 1.7 (#217). It fires on every `git pull` or `git merge --ff` that changes
HEAD, calling `roborev review --since ORIG_HEAD --branch <branch>` to cover the
just-arrived commits.

This is now the primary mechanism for pull-time coverage. The poller has been
downgraded to a thrice-daily safety net (see the parent rule's "Review Trigger
Mechanisms" section).

Phase 4 (full poller removal) is tracked in #217 — deferred until 7-day soak
confirms the hook is installed and firing on all watched repos.

## Auto-Verifier — install steps, pilot target, triage query

### Opt-in install steps

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

### Triage query (pending rejections)

```sql
SELECT id, finding_ids_json, fix_commit_sha, rejection_summary, attempted_at
FROM fix_rejected_queue
WHERE resolved = 0
ORDER BY attempted_at DESC
LIMIT 20;
```

## Merge Gate (dry-run mode) — verbose usage

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

## Merge-gate policy (#241, pilot HIGH) — local invocation examples

```bash
# Check before merging PR #253
bin/roborev_merge_gate.sh 253

# With explicit severity threshold
bin/roborev_merge_gate.sh --min-severity High 253

# JSON output (for scripting)
bin/roborev_merge_gate.sh --json 253

# Explicit repo (when not in a git checkout)
bin/roborev_merge_gate.sh --repo JohnGavin/llm 253
```

The `bin/` script exits 1 on block (enforcing mode). The predecessor
`~/.claude/scripts/roborev_merge_gate.sh` is dry-run only (always exits 0) and
is kept for week-1 signal logging. See that script's header for `--dry-run` /
`--enforce` flags.

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

## Sections Moved from the Rule Body (2026-07-29 line-limit pass, llm#749)

The sections below were moved verbatim out of the parent rule to bring it under
the 150-line config-size limit. They were previously part of the rule body.

### What roborev Does and Does NOT Do

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

### Documenting Findings

| Layer | Where | What |
|-------|-------|------|
| Per-commit | roborev DB | Raw findings (automatic) |
| Per-project | `project/knowledge/LOG.md` | High-severity findings + resolution |
| Cross-project | `llm/knowledge/wiki/roborev-patterns.md` | Recurring patterns → rule candidates |
| Global rules | `llm/.claude/rules/` | Graduated patterns (3+ occurrences) |

### Session-End Refine (Automated)

Runs automatically at `/bye`. Rollout completed (7-day soak, PRs #196/#202) — see this companion for the soak history.

#### What runs

`~/.claude/scripts/session_end_refine.sh`, invoked by `session_stop.sh` in the background via `nohup`, reads the session-start SHA (written by `session_init.sh` Phase 14 to `~/.claude/.session_start_sha_<sanitized-project-name>`) and calls:

```bash
timeout 120 roborev refine --since <session-start-sha> --max-iterations 3 --min-severity high --quiet --agent codex
```

#### Bounds and opt-out

| Bound / Mechanism | Value | Effect / Scope |
|-------|-------|--------|
| `timeout 120` | 2 minutes | Hard wall-clock kill |
| `--max-iterations 3` | 3 iterations | roborev internal cap |
| `--min-severity high` | High+ only | Skips low/medium noise |
| `nohup ... &` | Background | Never blocks `/bye` |
| Env var `SKIP_SESSION_END_REFINE=1` | Set before `/bye` | Session-level opt-out |
| TOML flag `session_end_refine = false` | In `.roborev.toml` | Per-project opt-out |

Logs to `~/.claude/logs/session_end_refine.log` (one line per session; result values `ok`, `timeout`, `error`, `skipped`).

### Review Trigger Mechanisms (Phase 1.7, #217)

#### Coverage model — three-tier

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
and the full poller-schedule decision history are earlier in this companion doc.

### Auto-Verifier (Component 4, JohnGavin/llm#163 Slice 3)

When a commit message cites `closes/fixes roborev #N` (validated by the Component 3
commit-msg hook), the auto-verifier triggers a re-review of the commit, polls until it
completes (max 120s), and on **approval** writes to the `closures` table + calls
`roborev close <id>`; on **rejection** writes to `fix_rejected_queue` for human triage;
on any failure (binary absent, DB unavailable, poll timeout) exits 0 (**fail-open**).

The verifier is **NOT auto-installed** — see "Auto-Verifier — install steps, pilot target, triage query" earlier in this companion doc.

#### DB schema (migration_v2)

Two new tables added to `~/.roborev/reviews.db` by `roborev_schema_migration_v2.sql`
(idempotent, `CREATE TABLE IF NOT EXISTS`):

| Table | Purpose |
|---|---|
| `closures` | Audit log of auto-close decisions (type: approved / wontfix / manual / stale) |
| `fix_rejected_queue` | Fix commits that roborev re-reviewed and rejected; requires human triage |

#### Kill switch

`SKIP_ROBOREV_VALIDATOR=1 git commit ...` disables for one commit. Uninstall via
`roborev_install_auto_verify_hook.sh --repo <path> --uninstall`. Reopen a wrongly
closed finding with `roborev reopen <finding_id>`. Log: `~/.claude/logs/roborev_auto_verify.log`.

### Merge Gate (dry-run mode)

Tracked in llm#241. MVP ships the dry-run script only — enforcement deferred.
`~/.claude/scripts/roborev_merge_gate.sh <pr#>` queries `~/.roborev/reviews.db` for
open findings whose `commit_sha` is in the PR's commits, then checks whether each
finding has been cited (`closes/fixes/acks roborev #N`) or explicitly acked via
`roborev_ack.sh`. Usage examples and the ack-flow CLI are earlier in this companion doc.

#### Verdicts

| Verdict | Meaning | Mode |
|---------|---------|------|
| `[gate-pass]` | 0 unresolved findings at threshold | always exits 0 |
| `[gate-warn]` | Medium-only unresolved findings | exits 0, week-1 signal |
| `[gate-block]` | High/Critical unresolved findings | dry-run: exits 0, enforce: exits 1 |

Reads `review_min_severity` from `.roborev.toml` (default `medium`). Logs to
`~/.claude/logs/merge_gate.log` (one JSON line per invocation).

#### Interaction with severity-autoclose (#224)

Autoclose operates on **aged** findings (>7d). The gate operates on **PR-current**
findings (any age on the PR's commits). The two do not cancel each other: a finding
autoclosed for age satisfaction is `closed=1` and therefore invisible to the gate.

#### Kill switch

`SKIP_MERGE_GATE=1` bypasses the gate in dry-run mode (exits 0 immediately). For
enforce mode, the kill switch is simply not invoking `--enforce`.

### Merge-gate policy (#241, pilot HIGH)

> No PR merges to `main` while any related roborev finding at severity ≥ `review_min_severity`
> (currently `High` in the pilot) is `closed=0` AND not cited by a `closes roborev #N`
> (or `acks roborev #N --reason …`) line in the PR's commits.

#### Definitions

| Term | Meaning |
|------|---------|
| **Related** | A roborev review whose `commit_sha` is in `git log origin/main..<head>` (commit-scope, Alternative C from #241 — tightest scope, avoids day-1 backlog freeze) |
| **Resolved** | `closed=1` in `~/.roborev/reviews.db` AND has a commit message citing it — OR — an explicit `acks roborev #N --reason "…"` commit |
| **Threshold** | Pilot: `High` (enforced by `bin/roborev_merge_gate.sh`). Per-repo override via `.roborev.toml` `review_min_severity` in Phase 3. |
| **Acked** | Waiver written to `~/.roborev/acks.jsonl` via `roborev_ack.sh --apply` with a written reason. Does NOT close the finding; closure is via fix-commit + auto-verifier (#163). |

#### Pilot escalation path

1. **Pilot (now):** `bin/roborev_merge_gate.sh` enforces HIGH only. Run before every merge.
2. **After 1 week of signal:** review `~/.claude/logs/merge_gate.log`. If block rate is low, escalate threshold to MEDIUM.
3. **Phase 3 (per-repo):** read threshold from `.roborev.toml` `review_min_severity` instead of hardcoded High.

Exit codes: `0` = PASS (no unresolved findings), `1` = BLOCK (unresolved findings found).
The `bin/` script enforces; the predecessor `~/.claude/scripts/roborev_merge_gate.sh` is
dry-run only (always exits 0), kept for week-1 signal logging. Local invocation examples
are earlier in this companion doc.

### launchd Job Health — Immediate Audit

If roborev or other automated jobs appear to have stopped running (e.g. autoclose log
is days stale, backlog is not updating), run `bin/launchd_health_audit.sh --quiet` — it
reports plists installed-but-not-loaded, loaded-but-failing, and stale jobs. Full
output-section breakdown and the weekly-health-email follow-up (llm#300) are earlier in
this companion doc.
