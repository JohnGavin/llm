# Companion: Verification Before Completion — Dated Worked Incidents

Dated worked-incident narratives split out of the always-loaded
[`verification-before-completion`](../verification-before-completion.md)
rule to keep it under the repo's line-count budget. The normative content
(The Iron Law, the falsification protocol, the Five Traps table, the
stricter-bar-for-safety-gates bullets, Verification Gate, Required Commands,
Post-Deploy Validation, One Change Per Verification Run's governing rule,
Before Any Commit, Verify Tool Output Counts, Red Flags, Forbidden vs
Correct) stays in the rule; this file is the dated worked incidents, loaded
on demand.

## Worked case, 2026-09-05 — a screenshot proved the wrong state (Trap B)

A headless-Chrome screenshot was used to "verify" a fix to an icon button's
hover tooltip: the screenshot showed the button rendered, bigger, with a
normal cursor — genuinely improved over the prior broken state — and was
reported as fixed. It was not: the actual complaint was about what the
tooltip *showed on hover*, and a static screenshot of the page's resting
state cannot render a `:hover`-triggered popover at all. The check was
real, ran fresh, and its output was read correctly — it simply verified a
different object (resting-state appearance) than the one the claim was
about (hover-triggered content). Textbook Trap B.

The user reported the popup still showed nothing. The fix that actually
worked (switching from a native `title=` attribute to a CSS
hover/focus-triggered popover) was verified correctly on the next attempt
by forcing the popover's visible state in a **scratch copy** of the
rendered file — never the file being shipped — via a throwaway CSS
override (`.pop > .pop-body { opacity: 1 !important; ... }`), then
screenshotting that copy. That screenshot showed the actual text content,
positioned and readable, which a resting-state screenshot structurally
cannot show. The scratch file was deleted immediately after.

General lesson: any check of `:hover`/`:focus`/`:active`-triggered CSS
needs either a tool that can drive a real pointer/focus event, or — cheaper
and sufficient for a one-off check — a scratch copy with the triggering
selector temporarily forced on, screenshotted, then discarded. A screenshot
of the untouched file only ever proves the resting state.

## Six checks in one session, 2026-08-21/22 — full incident list

Six checks in one session satisfied the Iron Law completely — each was run
fresh, its output read, its result quoted — while the thing each checked was
broken:

- a render harness that loaded a standalone YAML never read by the shipped
  page;
- a denylist canary present in a list that regenerates verbatim every run;
- a link audit that asserted range instead of correctness;
- `launchctl getenv` exiting 0 whether or not a variable exists;
- a child shell that inherited the variable under test;
- a CSS fix verified by having written it.

See `knowledge/wiki/lessons-learned-checks-that-cannot-fail.md` for the full
write-up. Sibling: `systematic-debugging`'s "Measure the Baseline Before
Claiming a Regression" is the same habit applied to causation, not
verification.

## Worked case, 2026-08-01 — the value of NOT cancelling a control run

A slow CI run verifying a dependency fix was left to finish rather than
cancelled in favour of a combined run. That control proved (a) the
dependency fix reached the previously-failing step, and (b) the *separate*
repo change produced an 11× speedup. Bundled, a fast green run would have
proved neither individually.
