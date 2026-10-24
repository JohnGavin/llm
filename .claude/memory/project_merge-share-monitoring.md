---
name: project-merge-share-monitoring
description: Owner wants owner-approved merges to fall and automatic ones to rise week over week; review dates and the levers to offer
metadata:
  type: project
---

On 2026-10-24 the owner said 65 owner-approved vs 10 automatic merges in 7 days is "too high" and asked me to monitor that automatic rises and manual falls as the week progresses, adjusting accordingly. Tracking is live: `merge_history_sync_all.sh` (PR 1518) and the "Merge approvals" block in the 06:30 email; a week-over-week trend and a placeholder target (40% automatic, owner set no number) are in a follow-up PR on branch `feat/merge-share-trend`.

**Why:** each owner-approved merge costs the owner a decision; the stated aim is fewer decisions, not a prettier ratio.

**How to apply:**
- RAISE FIRST on or after 2026-10-28 and 2026-10-31: read `merge_history_check.sh --daily`, report direction, name the largest owner-approved reason class.
- Levers, in order of safety: (1) batch related work into one PR; (2) extend the sweep to repos that have none (the biggest owner-only repos had 0 automatic); (3) add Tier 2 classes. Levers 2 and 3 widen authority: Class C, owner decides.
- Never relax a gate just to move the ratio. Also watch reverts of auto-merged PRs (the report prints `reverts: not tracked` if the column is missing).
- The 'unclassified' reason count was 20 of 83 on 2026-10-24: other repos are classified against the llm exclusion lists, so their reasons are weak.

Related: [[feedback-one-pr-per-feature]], [[project-tier2-widening-followups]].
