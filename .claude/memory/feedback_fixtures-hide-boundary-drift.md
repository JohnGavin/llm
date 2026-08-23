---
name: feedback_fixtures-hide-boundary-drift
description: A green suite of synthetic fixtures can miss a boundary bug that one run against real inputs exposes immediately — fixtures sit far from the boundary
metadata: 
  node_type: memory
  type: feedback
  originSessionId: fe01ad22-2ebd-4be6-ae17-84a4c52c1a36
  modified: 2026-08-23T13:41:24.751Z
---

A test fixture placed comfortably far from a boundary proves the boundary is
somewhere; it does not prove the boundary is in the right place. Run the code
against the real inputs before believing the suite.

**Worked case (llm#1001, 2026-08-23).** A date cutoff excluded files older than
`2026-08-22`. 18 assertions passed. The first run against the real attachments
directory skipped the exact file the change existed to recover — and skipped it
*quietly*, recording `skipped-pre-cutoff` and reporting `scan complete: 1
processed`.

Cause: BSD `date -j -f '%Y-%m-%d' 2026-08-22 '+%s'` fills every field the format
string does not mention **from the current time**, so the cutoff walked forward
through the day. At 13:00 it excluded a 09:50 file from that same morning. GNU
`date -d` does not do this. Fix: pin the time explicitly —
`date -j -f '%Y-%m-%d %H:%M:%S' "$D 00:00:00"`.

Why the suite missed it: the pre-cutoff fixture was stamped *January*. Months
away from the boundary, so drift of a few hours never showed. The test was
measuring the fixture's distance from the boundary, not the boundary's location.

**Why:** synthetic fixtures are chosen to make the intended branch fire, which
means they are chosen to sit far from the edge. Real data clusters at the edge —
that is what an edge is.

**How to apply:**

- Put at least one fixture *on* the boundary, not near it — a file stamped
  00:30 on the cutoff date, not one from three months earlier.
- Assert the boundary's resolved value directly (`does the cutoff land at
  00:00:00?`), not only the behaviour it produces. The behavioural test alone
  is time-of-day dependent; the property test is deterministic.
- Before claiming a fix works, run it against the real input the fix exists for,
  with outputs redirected somewhere harmless. Cheap, and it is what caught this.
- Mutation-check any assertion added for a bug: reinstate the bug and confirm
  the assertion fails. Here 20/0 became 18/2.

Related: [[feedback_nix-shell-portability]] (the GNU-vs-BSD split this is an
instance of), [[feedback_verify-causal-claims]] and
[[probe-must-not-share-writer-path]] — both about checks that return the
reassuring answer for reasons unrelated to the question.
