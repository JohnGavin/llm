---
paths:
  - ".claude/rules/dynamic-prose-values.md"
---

# Companion: Dynamic Prose Values — Violations Table and Origin Incidents

Worked violations and the dated origin incidents split out of the
[`dynamic-prose-values`](../dynamic-prose-values.md) rule, so the rule that
loads on every matching file stays lean. The normative content (one home per
value, how by output type, the build/publish gate, the proof steps, allowed
literals) stays in the rule; this file is loaded on demand.

## Violations

| Pattern | Problem | Fix |
|---------|---------|-----|
| `"29.9 m"`, `"2026-03-01"`, `"5 stations"` in prose | Hardcoded value/date/count | inline expression from the target |
| `"n = 9"`, `"6 of 9 sessions"` in a caption | Stale at session 10 | `data-fact` / inline R |
| `"0 of 42 charts mislabelled"` | Catalogue grew to 53 | count from the catalogue |
| Static thresholds table beside `dq_params()` | Two sources, will drift | generate from `dq_params()` |
| `title="... wrong for 5 of 9 sessions"` in JS | Invisible to a text-only gate | compute, or drop the count |
| A departure time typed in the booking **and** the day plan | Two copies | One record; the plan uses `{{ref:...}}` |
| `Version: 2026-08-29` / `Facts: 16` on a Build page | Values about the artifact | Derive from the version field and list lengths |
| A duplication check that skips times/dates/counts "as noise" | The exemption is the drift | Remove it; use a reasoned allow-list |
| A check that only warns, forever | Debt nobody reads | Ratchet to `strict` per artifact |
| Fixing only the numbers the user named | The rest stay stale | Run the gate over the whole page |

## Origin

Two incidents on 2026-09-25, both in private dashboard projects:

- A trip dashboard's Build page showed a hand-typed "Version 2026-08-29" and
  "Facts 16" after the data had changed twice. 89 restated values were
  measured across ~40 strings — clock times, dates, night counts and a
  traveller count that an earlier check had deliberately excluded.
- A chart title read n = 11 while its caption said "n = 9". A gate then found
  77 hand-typed numbers on one page, two already false, plus two reference
  tables maintained by hand. User: "never do this by hand again … make this
  mandatory."
