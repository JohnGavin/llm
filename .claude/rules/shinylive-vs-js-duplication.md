---
paths: ["**/*.qmd", "**/_pkgdown.yml", "**/shinylive/**"]
---

# Rule: Shinylive-vs-JS Dual Implementation — Decision Framework

## When This Applies

Any project considering shipping the SAME interactive feature (a quiz, a
calculator, a small dashboard widget) in both a vanilla-JS/pkgdown-native
form AND an R/Shiny-Shinylive (WASM) form — or reviewing whether an existing
dual implementation is still worth its cost.

## CRITICAL: A Dual Implementation Is a Loan, Not a Gift

Shipping both a JS version and a Shinylive version of the same feature buys
you the union of their capabilities on day one. It does NOT stay free. Every
later behavioural fix — a UI tweak, a state-machine correctness bug, a
styling change — must be implemented and independently verified in BOTH
stacks, because they share no code by construction (one is JS/DOM, one is R/
`reactiveValues`). The cost compounds with every fix, not just at build time.

**Corollary:** the decision to keep a dual implementation is not a one-time
choice — it has an expiry condition. Re-evaluate it whenever the *reason* you
built two (below) stops being true.

## Why Projects Reach for Shinylive Alongside JS (Legitimate Reasons)

| Reason | What it actually buys you |
|---|---|
| R-side computation the JS reimplementation can't feasibly match (a model fit, a simulation, a stats routine with no easy JS port) | Genuine capability gap — worth the cost |
| Faster initial prototyping in R before a JS port exists | Time-to-first-version; should be temporary |
| A standalone, embeddable app independent of the pkgdown site's build | A real, distinct product surface — decide this on its own merits, not as a "richer UI" side effect |

## The Failure Mode: Capability Convergence Nobody Re-Audited

The reason that actually got a project into trouble (micromort, 2026-09):
Shinylive shipped FIRST because, at the time, it was the only place with
score submission, percentile lookup, and calibration math. The JS version
was added later purely to fix Shinylive's 30-60s WASM boot time — a real,
deliberate speed/capability tradeoff, correctly reasoned at the time it was
made.

Over the following weeks, every one of those "Shinylive-only" capabilities
got ported to JS anyway (confidence capture, calibration display, reveal-
timing, scoring) — because fixing a bug in one implementation and not the
other left the two behaviourally inconsistent, and inconsistency is worse
than duplication. By the time this was audited, the ONLY capability still
exclusive to Shinylive was a ~20-line localStorage streak counter — a
trivially portable feature, not a real capability gap. The 60MB×3 WASM
bundle weight (180MB of a 288MB site) and the double-maintenance tax had
outlived their justification by months, and nobody had re-asked the
question because "we already built it" is not a trigger that fires on its
own.

**The lesson: the ORIGINAL justification for a dual implementation decays
silently as the leaner implementation gains parity feature-by-feature. Ask
periodically, not just at the moment you first considered dropping one:
"is the capability gap that justified keeping both still real?"**

## Decision Checklist

Before adding a SECOND implementation of an existing feature (or before
justifying keeping one you already have):

1. **Name the specific capability gap** the richer implementation provides
   that the leaner one genuinely cannot do — not "richer UI" as a vague
   label. If you can't name a concrete gap, you don't have one.
2. **Check whether recent fixes have already closed that gap** by accident
   — a bugfix applied to the leaner implementation to keep behavioural
   parity often silently ports the "missing" capability along with it.
3. **Measure the actual maintenance cost paid so far** — count how many
   separate PRs / verification passes a single behavioural fix required
   across both implementations. If it's consistently 2x work for 1x
   feature, that's the real price, independent of build size.
4. **Measure the build/deploy cost** — WASM bundle size, extra build steps
   outside the normal site pipeline (a Shinylive deploy typically needs an
   additional explicit "copy WASM output into the built site" step that
   the normal site-build target doesn't cover — easy to silently miss).
5. **Check whether any usage signal favours one implementation** — if both
   post to the same backing store (a shared Form/Sheet/DB) with no field
   distinguishing which implementation a user came from, you likely have
   NO usage evidence either way; don't invent a preference you can't
   measure.

If the named gap from step 1 is gone (step 2), the cost from steps 3-4 is
real, and step 5 gives you no data supporting the richer version — retire
it. Keep exactly one implementation per feature; if a *different*,
independently-justified reason exists for a standalone Shinylive app (e.g.
wanting one embeddable outside the pkgdown site), that's a reason to keep
ONE, not automatically all of them.

## Retiring a Dual Implementation Without Losing It

Retiring is not deleting. Preserve resurrectability cheaply:

```bash
git tag -a archive/<feature>-<date> <commit-before-removal> \
  -m "Archive point before retiring the Shinylive <feature> in favor of JS-only. See CHANGELOG.md / decision doc for rationale."
git push origin archive/<feature>-<date>
```

Then, in the same PR that removes the files:
- Port any genuinely-portable remaining capability (e.g. a small
  localStorage feature) to the surviving implementation FIRST, as its own
  reviewable step — don't bundle capability-porting with file deletion in a
  way that makes either hard to review independently.
- Add a redirect from the old URL to the surviving one (HTML meta-refresh
  or equivalent) so external bookmarks/links don't 404.
- Remove the now-dead build targets (the WASM render step + its separate
  deploy-copy step), not just the `.qmd` source file — an orphaned target
  left in the pipeline is a silent trap for a future rebuild.
- Write the decision down where a future reader will find it BEFORE
  re-deciding the same question from scratch — a CHANGELOG entry with the
  named capability gap (or its absence), the measured cost, and the tag
  name is enough; a full ADR is not required unless the project already has
  an ADR convention.

## Forbidden Patterns

| Pattern | Why wrong |
|---|---|
| "We already built both, may as well keep both" | Sunk cost, not a capability argument — re-run the checklist |
| Justifying a kept Shinylive version as "richer UI" without naming what it does that JS can't | Unfalsifiable — always re-derivable to "no gap found" |
| Deleting the `.qmd` without tagging the pre-removal commit | Removes cheap resurrectability for no benefit — a tag costs nothing |
| Removing the vignette file but leaving its build target in the pipeline | Next full rebuild either fails or silently rebuilds a dangling artifact |
| Assuming higher submission counts on one implementation means user preference, without a field that actually distinguishes them | No such field usually exists — don't manufacture a preference signal you don't have |

## Related

- `shinylive-webr-nonblocking` — implementation-level constraints once you've decided to build a Shinylive app (this rule is upstream of that one: whether to build it at all)
- `dashboard-filter-placement`, `visualization-standards` — UI conventions that apply regardless of which stack you pick
- `pr-shipping-discipline` — retiring code still goes through a PR, not a direct merge
- Origin case study: [JohnGavin/micromort#180](https://github.com/JohnGavin/micromort/pull/180), architecture review 2026-09-05 — 3 quiz topics (tracked in [#132](https://github.com/JohnGavin/micromort/issues/132)), each duplicated across JS + Shinylive, retired to JS-only after capability-gap audit found only a trivial streak-tracking feature remained Shinylive-exclusive
