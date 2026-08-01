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
