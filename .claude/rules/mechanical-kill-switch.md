---
description: Unattended automation that mutates shared state needs a halt-on-integrity-failure path, not just a performance/output-quality check — corrupted state, a breached invariant, or a previously-erroring step now silently degrading must stop the run, not merely log it
paths:
  - "bin/*cron*.sh"
  - "bin/*launchd*"
  - ".claude/scripts/roborev_auto_verify.sh"
  - ".claude/scripts/roborev_merge_gate.sh"
  - ".claude/launchd/**"
---

# Rule: Mechanical Kill Switches for Unattended Automation

## Press release (per `press-release-first`)

Any unattended automation that mutates shared state (a launchd job, roborev's
auto-verifier or merge gate, a scheduled `tar_make()`, an auto-refresh
ingestion job) must have a mechanical, deterministic path that **halts** the
run on an integrity failure — not merely one that reports success or failure
of the run's stated goal. A kill switch asks *"is this system doing what it
was built to do"* (corrupted state, a breached invariant, a check that used
to error now silently degrading) — a question with no false-positive cost
worth arguing about, unlike a performance-based stop rule.

## Chesterton check

The nearest existing rules are
[`checks-must-distinguish-unknown`](checks-must-distinguish-unknown.md) and
[`destructive-ops-guard`](destructive-ops-guard.md)/[`permission-discipline`](permission-discipline.md).
None of the three cover this gap:

- `checks-must-distinguish-unknown` requires a check to report
  fired/could-not-evaluate distinctly — it assumes a check exists and asks
  it to be honest about its own certainty. It does not require that
  *something* stands between "integrity failure detected" and "the
  automation proceeds anyway."
- `destructive-ops-guard`/`permission-discipline` classify and gate actions a
  human or agent is about to take deliberately (a `rm -rf`, a `gh pr merge`).
  They do not cover automation that decides, on its own, moment to moment,
  whether its own state is trustworthy enough to keep running.

This rule is the missing piece: a halt path triggered by **integrity**
failure in already-running unattended automation, distinct from both.

## Source

Originating issue: [historical#793](https://github.com/JohnGavin/historical/issues/793),
scoped to a trading-specific trigger table (exposure limits, position-size-vs-
intent). This rule is the general, cross-project version — the principle
belongs here so any project's automation can adopt it, while historical#793
stays open for the trading-specific implementation.

Motivating incident (Samir Varma, "I Read My Own Filing Cabinet," 2005): an
untested change to a downstream system caused an automated process to act at
~100× intended scale. Every upstream check was individually correct — the
failure was in the gap between validated logic and unattended execution, and
nothing was watching that gap mechanically.

## CRITICAL: A Performance Check Is Not a Kill Switch

A performance-based rule asks *is the output getting worse?* — a question
this codebase already has reasons to distrust when applied naively (see
`historical`'s `resulting-prohibition`/`underperformance-prior`, and the
literature on why naive drawdown rules fail).

A kill switch asks *is the system doing what it was built to do?* — a
mechanical, deterministic question given its inputs, with no interpretation
required at fire time.

## Trigger Categories (not thresholds — thresholds are per-surface)

| Trigger category | Example check |
|---|---|
| Corrupted / unreadable state | store meta unreadable; a target's schema differs from its recorded schema |
| Breached declared invariant | a value outside a declared hard cap, regardless of whether the overall run "succeeded" |
| Silent partial failure | a step that used to error now exits 0 with degraded output (the `error = "continue"` class) |
| Upstream input invalidated | a required input stops updating, disappears, or changes type/unit silently |
| Automation health itself | a scheduled job silently stops firing (partially covered today by `launchd_health_audit.sh`) |

## Requirements on Any Implementation

1. **Mechanical** — no judgement at fire time; the check is deterministic
   given its inputs.
2. **Loud and auditable** — a kill switch that silently no-ops is worse than
   none.
3. **Distinguishes fired from could-not-evaluate** — per
   `checks-must-distinguish-unknown`; a check that cannot read its input must
   never report "all clear."
4. **Decided ex ante, per surface** — what "halt" means (refuse to publish /
   refuse to write / refuse to enqueue) is decided when the automation is
   designed, not invented mid-incident.

## Candidate First Application

roborev's auto-verifier and merge gate already write to shared state (the
`closures` table, `roborev close`) unattended (see `roborev-resolution`). The
mechanism to build on already exists (`fail-open on gh errors, DB
unavailable` per that rule) — the gap is that "fail open" and "kill switch"
are opposite defaults, and per-surface it is not yet decided which one a
given write path needs. Treat that decision, and the surfaces named in this
rule's `paths:` frontmatter, as the first place to apply this rule in
practice.

## Explicitly Out of Scope

- Performance/drawdown-triggered de-risking — a separate, project-specific
  question (see historical's `resulting-prohibition`, `underperformance-prior`).
- The trading-specific trigger table (exposure limits, position sizing) —
  stays in historical#793.

## Related

- [`checks-must-distinguish-unknown`](checks-must-distinguish-unknown.md) —
  the fired/could-not-evaluate distinction this rule's requirement 3 reuses
- [`destructive-ops-guard`](destructive-ops-guard.md),
  [`permission-discipline`](permission-discipline.md) — existing mechanical
  guards this sits alongside, gating deliberate actions rather than ongoing
  automation integrity
- [`roborev-resolution`](roborev-resolution.md) — candidate first application
  (auto-verifier / merge gate)
- historical's `fail-loud-not-null` — the silent-coercion prohibition this
  generalizes to unattended automation
- [#1069](https://github.com/JohnGavin/llm/issues/1069) — origin issue
- historical#793 — originating, trading-specific issue
