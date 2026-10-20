---
name: project-tier2-widening-followups
description: "Owner widened auto-merge Tier 2 on 2026-10-20 (scheduled-script, state-table); follow-ups to verify it and open decisions on roborev finding delivery"
metadata:
  node_type: memory
  type: project
  originSessionId: 13c7d939-24e5-42f3-876c-c659b8212a8f
  modified: 2026-10-20T15:18:45.490Z
---

On 2026-10-20 the owner said "widen as recommended" and merged llm#1497: two new Tier 2 classes, `scheduled-script` (ordinary scheduled scripts + tests; destructive-named and hard-never scripts excluded) and `state-table` (additive rows only, to files on `.claude/state/auto_merge_state_tables.txt`, which holds only `job_failure_policy.tsv`). Owner said this was their last verb for this class and told me to stop asking for merges: Class C PRs wait quietly and are listed once a day, not asked about in conversation.

**Why:** 46 of 53 merges in 7 days needed an owner verb (29 excluded-path, 10-11 scheduled-script); the owner repeatedly pasted morning emails back to get failures explained.

**How to apply:**
- RAISE when the first Tier 2 merge happens (or by ~2026-10-27 if none): confirm the sweep took it after the 4 h veto window and `merge_history_check.sh` shows it as tier2 with no R1/R4 alert. A first real `state-table` PR is a new row in `job_failure_policy.tsv` with `Tier-2-Class: state-table`; do not invent a dummy row to test it.
- Do not ask the owner to merge in chat; put Class C PRs in one daily list.
- Open, not yet built: roborev high findings are not delivered back to the project that produced them (jobs 14366/14367, review finished ~1 h after the session ended). Proposed: /bye must prompt on any open finding at or above the autoclose threshold (my llm#1492 keyed only on count, a regression); a pending-findings pointer file read at session start; an immediate alert for sensitive repos. Related: llm#1296 (diff of private repos reaching a third-party agent).
- Open decisions on llm#1493 follow-up: 8 tracked files still name private projects (two registry CSVs, a worktree config example, two generated ccusage exports via llm#1390, three scan-blocked files needing other terms reworded).
- Related: [[one-pr-per-feature]], [[scanner-triage-followups]].
