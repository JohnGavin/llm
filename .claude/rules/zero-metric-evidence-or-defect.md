---
name: zero-metric-evidence-or-defect
description: A zero/empty/null metric in any report, dashboard, or summary is a DEFECT by default — it must be cross-checked against an independent source-of-truth count before being emitted. If the source has data but the metric is empty, fail loud (non-zero exit / alert), never silently render zeros.
type: quality
paths:
  - "**/*report*.R"
  - "**/*rollup*.R"
  - "**/*metrics*.R"
  - "**/*etl*.R"
  - "**/*_pulse.sh"
  - "**/send_*email*.R"
  - "**/*digest*.R"
  - "**/*summary*.R"
  - "**/*dashboard*.R"
  - "**/*dashboard*.qmd"
---

# Rule: Zero/Empty Metric = Defect Until Proven Otherwise

## When This Applies

Any code that produces a metric, count, rate, or aggregate for a human-facing
surface — a report, email digest, dashboard tile, weekly/daily rollup, ETL
summary table, or status banner. Applies to R, bash, SQL, and any language.

## CRITICAL: A headline `0` more often means "the source is empty/broken" than "nothing happened"

The recurring failure mode: a report reads from a source it cannot reach (wrong
path, missing package, dead/renamed table, crashed ETL), a `tryCatch`/`|| true`
swallows the error, and the surface renders `0` / `n/a` / "no data". The `0`
looks like a real result, ships in an email or dashboard, and the job exits `0`
— so nothing alerts. The reader trusts a number that means the opposite of what
they think.

**Default stance: an empty or zero metric is a DEFECT until evidence proves it
is a genuine zero.** The burden of proof is on the zero, not on the reader.

## The mandatory pattern: evidence check before emitting a zero

Every metric-producing path MUST, before rendering `0`/empty, run an
**independent evidence query** against the raw source of truth and compare:

```
evidence = <cheap COUNT against the raw source, no joins/filters that could hide rows>
result   = <the computed metric>

if evidence > 0 AND result is 0/empty:
    # the source HAS data but the metric came out empty → the pipeline is broken
    FAIL LOUD: exit non-zero, emit an INCONSISTENT/BROKEN marker, do NOT render zeros
else if evidence == 0:
    # genuinely nothing in the window → a real zero; render it, but ANNOTATE it
    # so a true zero is distinguishable from a broken zero
```

- The evidence query must hit a **different, more primitive** path than the
  metric (e.g. a raw table `COUNT(*)` vs a multi-join aggregate) so it can't
  share the metric's failure.
- A source that fails to open/attach/connect is a **hard error**, never a silent
  empty fallback.
- Guards must **exit non-zero** so cron/launchd surfaces the failure. A rollup
  or ETL that only logs a `WARNING` and continues to email zeros is forbidden.

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---|---|---|
| `tryCatch(query, error = \(e) empty_df)` then render | Swallows a broken source as a valid zero | Re-raise / exit non-zero when the source should have had rows |
| `count \|\| echo 0` in a report | A grep/query miss becomes a reported 0 | Check exit code; treat miss-with-populated-source as defect |
| Cron wrapper: rollup fails → `WARNING` → email anyway | Ships a misleading zero, exits 0, no alert | Propagate the non-zero exit; do not send the broken report |
| Reading a renamed/dead table (`closures`) that is now empty | Metric silently zero while real data moved to another column/table | Verify the source is live; evidence-check against the real source |
| One number, no cross-check | No way to tell empty-source from empty-reality | Add the independent evidence query |

## Relationship to consistency checks

This generalises the roborev cross-counter consistency check (#679): that catches
self-contradictory *roborev* state; this rule requires the same evidence-vs-result
discipline in **every** report/metric surface, and requires the failure to be
**loud** (non-zero exit / alert), not just logged.

## Origin

Recurring "a 0 that means the source is empty, not that nothing happened":

- `config_pulse.sh` counted 0 agents (read a removed `AGENTS.md`) — llmtelemetry#318/#319.
- Daily-report close-rate 0.0% (read the empty `closures` table) — llmtelemetry#323.
- Weekly rollup all-zero (RSQLite missing from nix env; `tryCatch` → empty) — llm#736/#737.
- Daily report "Zero-Action Data": 151 reviews, all action metrics 0 while 171 were really closed — llm#738.

## Related

- `.claude/rules/systematic-debugging.md`
- llm#679 (roborev cross-counter consistency check)
- llm#736, #737, #738; llmtelemetry#318, #323
