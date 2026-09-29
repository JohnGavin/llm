---
name: feedback_verify-inherited-conclusions
description: An audit, report or subagent conclusion is a claim — re-verify the one that drives your recommendation, and tell dispatched agents to verify the premise before editing
metadata:
  type: feedback
---

When a recommendation rests on a conclusion someone else produced (an audit document, a
subagent report, an earlier session), re-check that conclusion with a query before building on it.

**Why:** 2026-09-20. An audit said `fixer_heavy_day` "fires at its own floor, never actionable"
and I recommended retiring it. The dispatch told the agent to verify the premise first; it found
only 2 of 47 findings at the floor and 45 above it (39 of 52 dispatches on one day). Two more
claims from the same audit were also wrong or incomplete: dropping overnight sections 3c/3d
conflicts with `housekeeping-framework`, and ClaudeProbe was dormant (external CodexBar
producer), not dead. The audit generalised from the single row that happened to appear in one
email. Cost when caught early: nothing. Cost if not: a live detector deleted on a false premise.

**How to apply:** (1) before recommending removal of anything, run the Chesterton check
yourself: consumers by grep across `~/docs_gh/`, and the distribution of the thing, not one
example. (2) In every dispatch that acts on a claim, write "confirm the premise; report
'already fine' or 'premise false' as a successful outcome" — it worked three times in one day.
(3) Correct the source document when a claim is falsified, as a dated corrections section.
Companion: [[feedback_verify-causal-claims]].
