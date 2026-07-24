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
