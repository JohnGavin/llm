# Companion: Verification Before Completion — Dated Worked Incidents

Dated worked-incident narratives split out of the always-loaded
[`verification-before-completion`](../verification-before-completion.md)
rule to keep it under the repo's line-count budget. The normative content
(The Iron Law, the falsification protocol, the Five Traps table, the
stricter-bar-for-safety-gates bullets, Verification Gate, Required Commands,
Post-Deploy Validation, One Change Per Verification Run's governing rule,
Before Any Commit, Verify Tool Output Counts, Red Flags, Forbidden vs
Correct) stays in the rule; this file is the two dated worked incidents,
loaded on demand.

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
