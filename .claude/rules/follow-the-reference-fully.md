---
description: When given a reference artefact to follow, audit it fully and apply every applicable pattern in the first pass — never drip-feed one component per correction
paths:
  - "**/*.html"
  - "**/*.qmd"
  - "**/*.css"
  - "**/templates/**"
  - "**/_brand.yml"
---

# Rule: Follow the Reference Fully

## When This Applies

Any time an existing file is named as the model for new work: *"use X as a template"*,
*"match the style of Y"*, *"like the Z dashboard"*, *"follow our house pattern"*. Applies
to artifacts, dashboards, vignettes, documents, config, and code style.

## CRITICAL: A reference is a component library, not a stylesheet

The failure mode is treating the reference as a source of *look* — colours, fonts,
spacing — while inventing the *structure* from scratch. The result passes a glance and
fails on use, because the reference's components exist for reasons the new page shares.

The user then has to name the missing components one at a time, and each correction costs
a full round trip. That is the same instruction being given repeatedly, which is the
clearest possible signal the approach is wrong.

## The required first step: audit, then build

**Before writing a line**, enumerate what the reference actually contains:

```bash
# every class the reference defines
grep -o 'class="[^"]*"' reference.html | sort -u
# or, from its stylesheet
grep -oE '^\s*\.[a-z0-9-]+' reference.html | sort -u
```

Then, for each component, make an explicit decision:

| Verdict | Meaning |
|---|---|
| **Use** | The new content has this shape — apply it |
| **Not applicable** | The new content genuinely has no such element |

There is no third verdict. "I didn't notice it" and "I'll add it if asked" are the bug.

## Report the audit

State which components were used and which were deliberately skipped, so the user can
correct a *judgement* rather than an *omission*. A skipped component they wanted is a
one-word fix; an unnoticed one costs another round trip.

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---|---|---|
| Copying the reference's CSS but authoring new markup structure | Takes the look, drops the thinking | Audit components, map content onto them |
| Adding one component per user correction | Turns one instruction into N | Full audit in the first pass |
| "The template had tabs but this doesn't need them" — unstated | User cannot correct silent judgement | State skips explicitly |
| Treating a second request to use the template as a new instruction | It is the *same* instruction, unheeded | Re-audit the reference from scratch |

## Self-test

After building, diff the component inventories:

> Which classes does the reference use that mine does not — and can I justify each one?

If any answer is "no reason, I just didn't", the work is not finished.

## Origin

User, 2026-08-27, third repetition of the same instruction on one artifact: *"why do I
have to keep repeating that you should use the template … this is my 3rd time telling
you to do this, why cant learn?"* The reference's CSS tokens had been reused, but its
`tabset`, `day-body`, `plan.fine`/`plan.wet`, `day-note`, `steps`, `subhead` and
`linkrow` components were all ignored until named individually. A single up-front audit
would have caught every one.

## Related

- [`outbound-writing-style`](outbound-writing-style.md) — same family: match the
  established form rather than defaulting to your own
- [`uniform-typography`](uniform-typography.md) — consistency within a document set
- [`dashboard-table-styling`](dashboard-table-styling.md) — specific house patterns that
  a reference dashboard will already embody
