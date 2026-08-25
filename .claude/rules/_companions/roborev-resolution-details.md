# Companion: roborev Resolution — Verbose How-Tos and Reference Tables

Verbose-usage detail split out of the always-loaded
[`roborev-resolution`](../roborev-resolution.md) rule to bring it back under
its 300-line hard limit. Normative content (CRITICAL statements, decision
tables, current bounds/opt-outs, Forbidden Patterns) stays in the rule; this
file is worked examples, reference tables, and CLI usage. Dated incident
narratives and one-time rollout history live in
[`roborev-resolution-incidents.md`](roborev-resolution-incidents.md).

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

Cleanup script (idempotent, transaction-wrapped, previews then deletes rows
with `root_path` starting `/private/tmp/` or `/tmp/`):

```bash
sqlite3 ~/.roborev/reviews.db < ~/.claude/scripts/cleanup_ephemeral_repos.sql
```

Ephemeral entries are now also silently skipped during every polling run, so
this cleanup is optional. Why the table accumulates them: see the incidents
companion.

## Review Trigger Mechanisms — Three-Tier Coverage Model

| Tier | Trigger | Fires on | Introduced |
|------|---------|----------|------------|
| Primary | `post-commit` git hook | Every local `git commit` | Phase 1.0 |
| Secondary | `post-merge` git hook | Every `git pull` / `git merge --ff` that changes HEAD | Phase 1.7 (#217) |
| Safety net | launchd poller (thrice-daily, Mon–Fri 09:00/13:00/17:00) | Cron | Phase 1.7 (#217) |

The post-merge hook (`roborev_install_post_merge_hook.sh`) fires on every
`git pull` or `git merge --ff` that changes HEAD, calling `roborev review
--since ORIG_HEAD --branch <branch>` to cover the just-arrived commits — this
fills the gap where remote-merged PRs never trigger `post-commit` locally. The
poller is the last-resort backstop for repos without the hook installed, or
for merge paths that bypass both hooks (direct SHA pushes, force-pushes,
`git reset --hard`). Install steps + self-test: "Installing the post-merge
hook per repo" above. Phase 4 (full poller removal) is tracked in #217 —
deferred until a 7-day soak confirms the hook is firing on all watched repos.
Full schedule-decision history and reload instructions: incidents companion.

## Auto-Verifier (Component 4, JohnGavin/llm#163 Slice 3)

When a commit message cites `closes/fixes roborev #N` (validated by the
Component 3 commit-msg hook), the auto-verifier triggers a re-review of the
commit, polls until it completes (max 120s), and on **approval** writes to the
`closures` table + calls `roborev close <id>`; on **rejection** writes to
`fix_rejected_queue` for human triage; on any failure (binary absent, DB
unavailable, poll timeout) exits 0 (**fail-open**).

The verifier is **NOT auto-installed**. To install:

```bash
# 1. Apply DB migration (one-time/machine) — adds `closures` (audit log of
#    approved/wontfix/manual/stale) and `fix_rejected_queue` (needs triage)
sqlite3 ~/.roborev/reviews.db < ~/.claude/scripts/roborev_schema_migration_v2.sql

# 2. Dry-run to preview the hook content
bash ~/.claude/scripts/roborev_install_auto_verify_hook.sh --repo <path> --dry-run

# 3. Install (creates .git/hooks/post-commit → roborev_auto_verify.sh --apply)
bash ~/.claude/scripts/roborev_install_auto_verify_hook.sh --repo <path>
```

Uninstall: append `--uninstall` to the same command.

Pilot target: `t_demos` only, until ≥3 auto-closures and 0 wrong-closures.
Expand to other projects only after the pilot passes, and never to a project
with open Critical findings until the human-gate guardrail ships (Slice 4 /
Component 7).

Triage query (pending rejections):
```sql
SELECT id, finding_ids_json, fix_commit_sha, rejection_summary, attempted_at
FROM fix_rejected_queue
WHERE resolved = 0
ORDER BY attempted_at DESC
LIMIT 20;
```

Kill switch: `SKIP_ROBOREV_VALIDATOR=1 git commit ...` disables for one
commit. Reopen a wrongly closed finding with `roborev reopen <finding_id>`.
Log: `~/.claude/logs/roborev_auto_verify.log`.

## Merge Gate (dry-run mode)

Tracked in llm#241. MVP ships the dry-run script only — enforcement deferred.
`~/.claude/scripts/roborev_merge_gate.sh <pr#>` queries `~/.roborev/reviews.db`
for open findings whose `commit_sha` is in the PR's commits, then checks
whether each finding has been cited (`closes/fixes/acks roborev #N`) or
explicitly acked via `roborev_ack.sh`.

```bash
~/.claude/scripts/roborev_merge_gate.sh 253                    # dry-run (default) — always exits 0
~/.claude/scripts/roborev_merge_gate.sh --branch feat/my-feature  # auto-detects PR#
~/.claude/scripts/roborev_merge_gate.sh --enforce 253           # enforce mode (not active yet — future CI)
```

Logs to `~/.claude/logs/merge_gate.log` (one JSON line per invocation).

Verdicts:

| Verdict | Meaning | Mode |
|---------|---------|------|
| `[gate-pass]` | 0 unresolved findings at threshold | always exits 0 |
| `[gate-warn]` | Medium-only unresolved findings | exits 0, week-1 signal |
| `[gate-block]` | High/Critical unresolved findings | dry-run: exits 0, enforce: exits 1 |

Reads `review_min_severity` from `.roborev.toml` (default `medium`). Interacts
with severity-autoclose (#224): autoclose closes **aged** findings (>7d); the
gate checks **PR-current** findings (any age on the PR's commits) — a finding
autoclosed for age is `closed=1` and therefore invisible to the gate, so the
two mechanisms don't cancel each other.

Kill switch: `SKIP_MERGE_GATE=1` bypasses the gate in dry-run mode (exits 0
immediately). For enforce mode, the kill switch is simply not invoking
`--enforce`. Week-1 rollout data plan: incidents companion.

**Ack flow for false positives:** `~/.claude/scripts/roborev_ack.sh 42
--reason "false positive — nix-only path" --pr 253` dry-runs (shows what
would be written); add `--apply` to write to `~/.roborev/acks.jsonl`. Include
the printed line in your commit message: `acks roborev #42 --reason "false
positive — nix-only path"`. The ack does NOT close the finding in
`reviews.db`; closure happens via fix-commit + auto-verifier (#163) or manual
`roborev close`.

## Merge-gate policy (#241, pilot HIGH)

> No PR merges to `main` while any related roborev finding at severity ≥
> `review_min_severity` (currently `High` in the pilot) is `closed=0` AND not
> cited by a `closes roborev #N` (or `acks roborev #N --reason …`) line in the
> PR's commits.

| Term | Meaning |
|------|---------|
| **Related** | A roborev review whose `commit_sha` is in `git log origin/main..<head>` (commit-scope, Alternative C from #241 — tightest scope, avoids day-1 backlog freeze) |
| **Resolved** | `closed=1` in `~/.roborev/reviews.db` AND has a commit message citing it — OR an explicit `acks roborev #N --reason "…"` commit |
| **Threshold** | Pilot: `High` (enforced by `bin/roborev_merge_gate.sh`). Per-repo override via `.roborev.toml` `review_min_severity` in Phase 3. |
| **Acked** | Waiver written to `~/.roborev/acks.jsonl` via `roborev_ack.sh --apply` with a written reason. Does NOT close the finding. |

```bash
# Check before merging PR #253
bin/roborev_merge_gate.sh 253
bin/roborev_merge_gate.sh --min-severity High 253
bin/roborev_merge_gate.sh --json 253               # scripting
bin/roborev_merge_gate.sh --repo JohnGavin/llm 253  # explicit repo
```

Exit codes: `0` = PASS, `1` = BLOCK, `2` = usage error, `3` = **INDETERMINATE**.
The `bin/` script enforces; the predecessor
`~/.claude/scripts/roborev_merge_gate.sh` is dry-run only (always exits 0),
kept for week-1 signal logging.

**Exit 3 is not a pass.** It means the gate could not evaluate the PR at all —
`gh` missing or unrunnable, `gh` rejecting auth (a stale `GH_TOKEN` does this),
the repo unresolvable, or `reviews.db` absent. Before llm#1012 every one of
those exited 0 and printed the word `PASS`, so the gate on this machine had
never inspected a finding and was structurally incapable of blocking. Treat a
3 the way you would a 1: stop and fix the cause. `MERGE_GATE_FAIL_OPEN=1`
downgrades it to exit 0 for callers that deliberately accept the risk — the
output still reads INDETERMINATE, never PASS.

Regression cover: `tests/test_roborev_merge_gate.sh` tests 9–14. Each drives
the gate into an unanswerable state and asserts both `exit == 3` **and** that
the output does not contain the string `PASS`; test 14 is the control that a
working gate still reaches a real verdict.

Pilot escalation path:
1. **Pilot (now):** `bin/roborev_merge_gate.sh` enforces HIGH only. Run before every merge.
2. **After 1 week of signal:** review `~/.claude/logs/merge_gate.log`. If block rate is low, escalate threshold to MEDIUM.
3. **Phase 3 (per-repo):** read threshold from `.roborev.toml` `review_min_severity` instead of hardcoded High.

## Session-End Refine (Automated)

Runs automatically at `/bye`. `~/.claude/scripts/session_end_refine.sh`,
invoked by `session_stop.sh` in the background via `nohup`, reads the
session-start SHA (written by `session_init.sh` Phase 14 to
`~/.claude/.session_start_sha_<sanitized-project-name>`) and calls:

```bash
timeout 120 roborev refine --since <session-start-sha> --max-iterations 3 --min-severity high --quiet --agent codex
```

| Bound / Mechanism | Value | Effect / Scope |
|-------|-------|--------|
| `timeout 120` | 2 minutes | Hard wall-clock kill |
| `--max-iterations 3` | 3 iterations | roborev internal cap |
| `--min-severity high` | High+ only | Skips low/medium noise |
| `nohup ... &` | Background | Never blocks `/bye` |
| Env var `SKIP_SESSION_END_REFINE=1` | Set before `/bye` | Session-level opt-out |
| TOML flag `session_end_refine = false` | In `.roborev.toml` | Per-project opt-out |

Logs to `~/.claude/logs/session_end_refine.log` (one line per session; result
values `ok`, `timeout`, `error`, `skipped`). Rollout is complete — soak
history in the incidents companion.

## launchd Job Health — Immediate Audit

If roborev or other automated jobs appear to have stopped running (e.g.
autoclose log is days stale, backlog is not updating), run:

```bash
bin/launchd_health_audit.sh --quiet
```

Output sections:
- **Section 2** (Loaded, failing) — jobs loaded but last exit code was non-zero.
- **Section 3** (NOT loaded) — jobs with plists installed but not loaded; these
  will never fire. Fix with: `launchctl load -w ~/Library/LaunchAgents/<label>.plist`
- **Section 4** (Stale) — jobs loaded but haven't fired within 1.5× their cadence.

Common trigger: after a macOS update or logout/login cycle, launchd may unload
all user agents. The weekly health email (llm#300) will automate this check
once its `launchd_runs` ledger is populated; until then, run this audit any
time a roborev job looks stale.

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

## Documenting Findings

| Layer | Where | What |
|-------|-------|------|
| Per-commit | roborev DB | Raw findings (automatic) |
| Per-project | `project/knowledge/LOG.md` | High-severity findings + resolution |
| Cross-project | `llm/knowledge/wiki/roborev-patterns.md` | Recurring patterns → rule candidates |
| Global rules | `llm/.claude/rules/` | Graduated patterns (3+ occurrences) |
