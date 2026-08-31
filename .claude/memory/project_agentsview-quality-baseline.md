---
name: project-agentsview-quality-baseline
description: "Status and lessons from establishing a trustworthy AgentsView quality baseline (llm#1115) — what's done, what's deferred, and why"
metadata: 
  node_type: memory
  type: project
  originSessionId: a3346af5-65b1-4df8-a747-936bd4171ae8
  modified: 2026-08-31T20:07:48.851Z
---

## Status as of 2026-08-31

Origin: [llm#1115](https://github.com/JohnGavin/llm/issues/1115) — a survey found
raw `agentsview session list`/`agentsview projects` counts are close to
uncorrelated with actual scoreable data (81.9x compression across 15 projects
surveyed: 15,646 raw sessions → 191 substantive). Re-verified live before acting
on it (re-ran the `llm` and `JohnGavin.github.io` queries; both matched within
expected snapshot drift) — the survey's methodology held up under a second check.

Labelled `P0-blind-spots` and cross-referenced against #932's priority taxonomy:
reclassified from #932's P6 (self-improvement/eval, marked *blocked on P0*) to P0
itself, because this is establishing whether a metric can be trusted at all, not
downstream work that depends on P0 already being clear.

**Done (2026-08-31):**
- `.claude/rules/agentsview-quality-baseline.md` — codifies the substantive-session
  definition (`message_count>=30 AND is_automated==false`), the filtering recipe,
  and all four verified caveats (multi-bucket cwd-splitting, short-sessions-score-100,
  `projects`-count vs `session list`-count disagreement, the `--min-messages`+
  `--include-children` interaction bug).
- `.claude/scripts/agentsview_quality_baseline.sh` — scripts that recipe (see the
  rule file for full spec; check the PR referenced on #1115 for the actual landed
  form, since this note may predate or postdate the merge).

**Deferred, explicitly, on purpose (not forgotten):**
- **Monthly periodic re-run** (issue's step 3) — depends on the script above
  existing first; slot into an *existing* housekeeping cadence per
  `housekeeping-framework`'s "check for an existing slot first" rather than a new
  launchd job.
- **Confirming the `--min-messages`+`--include-children` bug upstream** — agentsview
  is third-party; low urgency since a workaround (don't combine the flags) already
  exists.
- **Fanning out "adopt this filter" issues to the other 14 surveyed projects** —
  deliberately NOT done. Reasoning: most of those projects are `too-thin`/`building`
  tier, so over-interpreting a 2-3-session average and proactively filing issues
  elsewhere would repeat the exact "small-sample noise treated as signal" mistake
  the survey warns against. Only the two genuinely actionable per-project findings
  (one project's 10x tool-failure rate; the 10,000-session/1-substantive-session
  project) are worth a direct heads-up to their owners — not a generic cross-repo
  issue blast. If a future session works in one of those specific projects, surface
  it there; don't do it centrally.
- **`llm`'s own D:3/F:1 grade tail** — flagged as "worth a look" in #1115 but no
  follow-up issue opened yet; this was a recommendation, not something explicitly
  approved for action.

## Lesson worth keeping

The survey's own "Verification performed" section (independent re-derivation,
re-checking zero-results at a lower threshold to rule out dead queries, a second
session cross-checking the drafting agent's numbers) is why it survived a live
re-check months... well, hours later without correction. That's the bar for this
kind of cross-project numeric claim — see [[feedback_verify-causal-claims]] for the
general version of this discipline.
