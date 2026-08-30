# Companion: roborev Resolution — Dated Incidents and Rollout History

Dated incident narratives and one-time rollout procedures split out of
[`roborev-resolution-details.md`](roborev-resolution-details.md) to keep that
companion under its 300-line hard limit. Current-state normative content
(bounds, opt-outs, decision tables) stays in the details companion and in the
parent [`roborev-resolution`](../roborev-resolution.md) rule; this file is
historical record only, loaded on demand.

## Coverage Gap — Lesson 2026-05-13: remote-merged PRs don't fire post-commit

`post-commit` only fires on **local** `git commit`. PRs merged on GitHub (web
UI, `gh pr merge`, auto-merge) reach the repo via `git fetch` / `git pull` /
`git merge --ff` — **none of these trigger `post-commit`**. Projects that do
most work via PRs therefore had near-zero roborev coverage despite the hook
being installed.

Symptom: roborev DB shows no jobs for a repo for hours/days despite commits
being on `origin/main`. Diagnosis and backfill commands are in the parent
rule's "Coverage Model" section. This gap is now closed by the post-merge
hook + thrice-daily poller — see the "Review Trigger Mechanisms" section in
the details companion for the resulting three-tier model.

## Session-End Refine Rollout — SKIP defaulted ON (7-day soak) — COMPLETE

The 7-day soak ran from 2026-05-20 (PR #196 merged) to 2026-05-27. During the
soak, `session_stop.sh` invoked `session_end_refine.sh` with
`SKIP_SESSION_END_REFINE=1` prefixed so each call exited early with
`result=skipped`. The log confirmed: `session_init.sh` Phase 14 wrote the
start-SHA file correctly; `session_stop.sh` fired the script at each `/bye`;
cwd-detection and project-name sanitisation found the right project; nothing
in `/bye` became noticeably slower.

The `SKIP_SESSION_END_REFINE=1` prefix was removed in PR #202 (merged
2026-05-27). The refine now runs by default at every `/bye` (current bounds:
"Session-End Refine" in the details companion).

## Poller Schedule Decision (2026-05-23 → 2026-06-01, #217)

| Date | Schedule | Fires/week | Reason for change |
|------|----------|------------|-------------------|
| Initial | Every 15 min, 24/7 | ~672 | First implementation |
| 2026-05-23 | Hourly, Mon–Fri 09:00–22:00 | ~70 | Eliminate overnight no-ops |
| 2026-06-01 | Thrice-daily, Mon–Fri 09:00/13:00/17:00 | 15 | Post-merge hook now provides primary coverage |

Issue #217 diagnosed the poller log showing repeated `behind=0 enqueued=0`
runs during overnight and weekend hours — no PRs are merged outside working
hours in this solo development context, so every off-hours fire was a no-op
burning launchd overhead and polluting the log.
`com.claude.roborev-poll-merges.plist` now fires at 09:00, 13:00, and 17:00
on weekdays only. The post-merge git hook is the primary mechanism for
pull-time coverage; the poller is the safety net.

Reload after editing the plist:
```bash
launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.claude.roborev-poll-merges.plist
cp /Users/johngavin/docs_gh/llm/.claude/launchd/com.claude.roborev-poll-merges.plist \
   ~/Library/LaunchAgents/com.claude.roborev-poll-merges.plist
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.claude.roborev-poll-merges.plist
launchctl print "gui/$(id -u)/com.claude.roborev-poll-merges" | grep -A2 calendar
```

Phase 4 (full poller removal) is tracked in #217 — deferred until a 7-day
soak confirms the post-merge hook is installed and firing on all watched
repos.

### Why the `repos` table needed cleanup

The poller once reported `total=55` repos because roborev's `repos` table
accumulates every path ever passed to `roborev review`, including ephemeral
`/private/tmp/` worktree checkouts from agent runs — noise in the poller's
per-repo scan loop. See "Cleaning ephemeral entries" in the details
companion for the cleanup command (now largely unnecessary, since ephemeral
entries are auto-skipped).

## Merge Gate — Week-1 Data Plan

For the first week after shipping the dry-run merge gate, the plan was to run
the gate on every PR before merge and let it log to
`~/.claude/logs/merge_gate.log`, then after 1 week: review the log for
gate-block/gate-warn counts; file a follow-up issue with the enforce-mode
decision; if the High/Critical block rate was low, enable `--enforce` for
High/Critical only; update the PR template to make the checklist row
mandatory. Superseded by the pilot policy in the details companion's
"Merge-gate policy" section.

## Requeue Dropped Quota Failures — measured results and exclude_patterns trap (llm#927, 2026-08-14)

roborev retries a job internally, but once `retry_count` exhausts its cap,
`status='failed'` is TERMINAL — nothing revisits the commit after the agent's
quota resets. `roborev_poll_merges.sh` only looks for *unreviewed commits
since a ref*, not *failed jobs to retry*, so a quota-exhausted commit is
DROPPED, not deferred.

`.claude/scripts/roborev_requeue_dropped.sh` finds `review_jobs` rows with
`status='failed'`, `commit_id IS NOT NULL`, whose `error` matches a verified
quota/spend pattern (`spend limit`, `quota`, `usage limit`, `hit your limit`,
`session limit`, `rate limit` — confirmed against the real DB, not guessed),
and whose commit has no successful review (`done`/`applied`/`rebased`) and no
job already in flight (`queued`/`running`). It re-enqueues up to `--limit`
(default 5) of them via `roborev review --sha <sha> --repo <root_path>`.

**The exclude_patterns trap:** before enqueueing, every candidate's
changed-file list is checked against its OWN repo's `.roborev.toml`
`exclude_patterns` (see `roborev-exclude-patterns` rule). A commit that
touches ONLY excluded paths (e.g. llmtelemetry's regenerated
`inst/extdata/**`) is skipped, not enqueued — otherwise the sweep would
re-automate exactly the noise `exclude_patterns` exists to remove (see that
rule's llmtelemetry case study). When the check cannot be made reliably
(repo checkout missing locally, or the commit's git object is
missing/history was rewritten since the job was recorded) the candidate is
ALSO skipped and reported — never guessed into an enqueue.

Measured 2026-08-14 against the real DB: 153 candidates, 87 correctly
skipped as excluded (mostly llmtelemetry bot-data commits, plus 2
`historical` CHANGELOG-only commits), 10 skipped as unavailable (missing
checkout / rewritten history), 51 held back by the default `--limit=5`, 5
offered for enqueue — all real code, in `coMMpass`, which has no
`exclude_patterns` configured.

**Wired into `com.claude.roborev-poll-merges`** (fires thrice daily,
Mon–Fri 09:00/13:00/17:00) — no new launchd plist was added, per the
`housekeeping-framework` rule's "check for an existing slot first"
discipline. `roborev_poll_merges.sh` calls `roborev_requeue_dropped.sh`
after its own primary per-repo catchup work completes, mirroring the
poller's own dry-run/`--apply` mode with a fixed `--limit=5`. The call is
fail-open (missing/non-executable script, missing `timeout` binary, or a
non-zero exit all degrade to a logged skip — the poller's own summary and
exit code are never affected) and bounded by `timeout 120`. Opt out with
`SKIP_ROBOREV_REQUEUE=1` (naming mirrors `SKIP_SESSION_END_REFINE`). Every
invocation — including skips — is logged to
`~/.claude/logs/roborev_poll_merges.log` under a `requeue-sweep:` prefix,
so the sweep never runs silently. Housekeeping heartbeat: a
`task='roborev_requeue_dropped'` row in `housekeeping_runs`
(`~/.claude/logs/unified.duckdb`), written on every invocation including a
zero-candidate run.

## Eval Harness origin incident — full narrative (llm#1044, llm#1035)

roborev is a third-party closed-source binary we cannot patch. We have no
automated evaluation of its review *quality* — only that a job ran.
Concretely: gemini-2.5-flash-lite silently failed to read the diff on 15.5%
of its 129 open reviews in this repo (20 of them) — nobody noticed until a
human hand-queried `~/.roborev/reviews.db` during an unrelated bug
(llm#1035). Nothing caught it on the day the agent/model config changed.

The harness (`.claude/scripts/roborev_eval_run.sh`) replays 5 golden diffs
(`.claude/tests/fixtures/roborev_eval/`) through the live `roborev review
--dirty --local --wait` and classifies each result as `PASS` / `FAIL` /
`ERROR` / `TIMEOUT` — an `ERROR` (nonzero exit, or the exit-0-but-empty-result
silent-failure signature from llm#1035) is never folded into a pass, per
`checks-must-distinguish-unknown`. This is documentation-as-gate, not an
automated hook — no PreToolUse hook intercepts `roborev config set`; a human
runs this manually before trusting a config change. Judge-disagreement
tracking, safety sampling of auto-closures, and an error taxonomy are
explicitly out of scope for this slice (see llm#1044).

## Known Issues — full narratives

- **`.roborev.toml` is gitignored in some projects** (e.g., micromort) but
  tracked in others (coMMpass, llm). Edits in gitignored projects are
  LOCAL-only and silently disappear if `roborev init` regenerates. Check
  `git check-ignore .roborev.toml` before editing; if ignored, add a
  top-of-file comment recording the manual value.

- **`"parse error: no valid stream-json"` is a FABRICATED cause, not a real
  diagnosis (llm#954).** roborev is a compiled third-party binary we cannot
  patch. When an agent process exits non-zero with EMPTY stdout, roborev
  cannot parse the stream-json it expected and reports this message —
  describing its *own* parsing step, not the agent's actual failure. The
  real cause (missing/expired API key, network failure, quota exhaustion,
  anything on the agent's stderr) is discarded and never logged. Diagnosis:
  **run the agent's exact command manually with the same flags and read
  stderr** — that single step finds the real cause; the roborev log line
  cannot. Detection: the overnight email (`send_overnight_self_review_email.R`)
  reports, per agent over 24h/7d, the count of `review_jobs` rows matching
  `status='failed' AND error LIKE '%no valid stream-json%'` and the max
  **consecutive** run for that agent (query: gaps-and-islands over
  `review_jobs` ordered by `enqueued_at`, joined via DuckDB's sqlite
  extension against `~/.roborev/reviews.db`) — an unbroken streak ≥ 3 means
  that agent is wholly broken, not intermittently flaky. Origin: a gemini
  episode ran 22+ consecutive failures (2026-08-06 onward) before being
  found by manual process archaeology, not by any roborev log line.

- **`--agent X` on `roborev compact` does not reliably control every
  sub-step (llm#411).** `compact` has at least three sub-steps —
  verification (checks a finding against current code), consolidation
  (creates the new compact review record), and a further internal call that
  can invoke a *different* agent than either `--agent` or the
  `default_agent`/`fix_agent`/`refine_agent` config keys specify. Reproduced
  2026-06-01 (mycare): `--agent claude-code` produced a verification log
  line reading `codex`, and a separate run failed on a `gemini` fork/exec
  error despite `--agent claude-code` being passed and no config key naming
  gemini at all. Setting `default_agent`/`default_backup_agent`/`fix_agent`
  globally to `claude-code` did not make every sub-step honour it. roborev
  is a compiled third-party binary — we cannot patch its argument-precedence
  logic, only observe and route around it. **Workaround:** pass `--agent
  claude-code` explicitly on every `compact` invocation, and accept that a
  given run may still invoke an unexpected agent for one sub-step; if it
  does, rerun rather than debugging the precedence further. Not worth
  upstream-reporting effort at current severity (low operational pain, no
  data loss) — revisit only if consolidation starts silently invoking a
  *rate-limited* agent often enough to block real work.
