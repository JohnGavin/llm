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

## Worked case, 2026-08-31/09-01 — an SPA layout claim needs real interaction, not static analysis (Trap B)

Two consecutive PRs (micromort #137, #139) "fixed" a page-layout complaint
— content reappearing while scrolling through a JS-driven quiz — and both
were verified only via `jsdom`-against-saved-HTML and `curl`+`grep` against
the deployed page. Both were wrong in production: the content was
collapsed and repositioned in the DOM, but because it sat immediately
after the SPA's own redrawing container, it still appeared directly below
every answered question once a real user scrolled. `jsdom` executed the
page's JS correctly and the markup genuinely contained the intended
change — the check inspected the right *code*, but jsdom does not render
CSS at all, so a layout/positioning bug is invisible to it by
construction, regardless of how faithfully it runs the script. Only
loading the live page with `puppeteer-core` against a real, installed
Chrome, clicking through the actual interaction, and screenshotting the
result caught it. Full incident: [micromort#142](https://github.com/JohnGavin/micromort/issues/142).

The distinction from the 2026-09-05 hover case above: that one needed only
a *triggering event* (`:hover`) in an otherwise-adequate rendering
pipeline. This one needed a rendering pipeline capable of CSS layout at
all — no amount of triggering the right event inside `jsdom` would have
surfaced it, because `jsdom` has no layout engine to get wrong. Static
analysis of any kind — `grep` on deployed HTML, confirming a CSS rule or a
JS function exists in source, a `jsdom`-executed click-through — proves
the code *shipped* and, at best, that the *script* ran without error; none
of it proves what a user *sees* after a real browser lays the page out.
For a UI/layout claim about a client-side-rendered page (one that mutates
its DOM via JS rather than reloading per state), drive real interaction —
load, interact, observe — in a rendering engine that actually does CSS
layout. See `browser-user-testing`'s puppeteer-core-against-system-Chrome
fallback for the concrete tooling, and
[`verify_html_artifact_js.sh`](../../scripts/verify_html_artifact_js.sh)
(JohnGavin/llm#1129) for what a `jsdom`-based check *does* prove and
where its scope stops: it is real, executed verification that a page's
inline JS runs without an uncaught error and that the click handlers it
finds actually fire and produce their expected DOM state (a class, an
`open` attribute) — a materially stronger check than `node --check` or a
structural tag-balance count, and one that would have caught the
*separate*, unrelated `tennis`-project incident this rule's Trap A section
already documents (an uncaught `ReferenceError` aborting all click-handler
wiring). But it is not, and cannot become, a substitute for the
CSS-layout verification this incident needed — the two tools answer
different questions and neither is a superset of the other.

A related, separate mistake in the same investigation: a `git grep` for a
feature that was in fact shipped came back empty and nearly caused a
wrongly-diagnosed "it's missing" claim — the local checkout's working tree
was 12 commits behind `origin/main` and had never been `git pull`ed.
Reading a local file is not the same as reading the current committed
state; `git show <ref>:<path>` (or a `git status`/fetch check first) is
required when the local working tree's freshness hasn't been confirmed.
Sibling lesson: `systematic-debugging`'s "Measure the Baseline Before
Claiming a Regression."

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
