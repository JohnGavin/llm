---
name: feedback_fix-every-instance-or-justify-the-exclusion
description: When a diagnosis finds N instances and you fix a subset, the criterion for excluding the rest is itself a claim — "hasn't fired yet" is not "won't fire", and the cost asymmetry usually settles it without needing to know
metadata:
  type: feedback
---

A correct diagnosis narrowed to the wrong scope still ships a broken system.

**What happened (2026-08-26/27, llm#1034 then llm#1036).** A dialog appeared
every morning: *"bash would like to access data from other apps."* The mechanism
was diagnosed correctly and from evidence — Homebrew bash is ad-hoc signed, so
macOS stores its TCC grant with an **empty csreq** and cannot bind the grant to
a code identity, so it re-prompts forever. The checker written alongside the fix
found **six** launchd scripts routing through that interpreter via
`#!/usr/bin/env bash`.

One was fixed. The other five were demoted from findings to "context", with this
written into the code as justification:

> *"exactly one of six touches a TCC-protected resource, so flagging all six
> would have people editing five shebangs for no reason"*

That sentence is an inference from a **single 12-hour sample**, stated as
knowledge. It was true of that sample. The next day `com.roborev.auto-refine` —
a `KeepAlive` daemon running one of the five — produced **11 prompts**, because
the agents it spawns run `find` and sandboxd brokers that. Nothing had changed
except which jobs happened to be busy.

**Why:** the fix for the targeted job worked perfectly (its 09:00 prompt never
came back). The failure was entirely in the scoping decision, and scoping felt
like housekeeping rather than a claim, so it was never evidenced.

This is the **blast-radius** clause of [[feedback_verify-causal-claims]] applied
in the other direction. That memory says do not assert a blast radius without a
query. The same rule governs asserting a blast radius is *small*: "these five are
unaffected" needs evidence exactly as much as "these five are affected".

**How to apply:**

1. **When a diagnosis finds N instances, the default is fix all N.** Excluding
   any of them is a claim that needs its own evidence, written down next to the
   exclusion.
2. **"Not observed failing" is not "will not fail."** Absence in a sample is the
   weakest possible evidence, and it is exactly what a short observation window
   produces. Ask what the sample could not have seen.
3. **Let the cost asymmetry decide when you cannot get certainty.** Here: a false
   positive cost one shebang edit; a false negative cost a permanent recurring
   dialog and a second incident. That was knowable up front and settles it
   without needing to know which scripts touch protected paths.
4. **A latent defect is still a defect.** An env-shebang on a launchd job is
   broken the day the job first touches a protected path, whether or not that
   has happened. Detectors should flag the condition, not wait for the symptom.

**Corollary, same 24 hours.** The follow-up was nearly mis-scoped too: the surge
was first blamed on a credential-hygiene sweep added that morning, on a clean
timing correlation — it landed 10:04, the first new prompt was 23:24 the same
day. Running its exact `find` produced **zero** TCC requests. The correlation was
coincidence. Testing an attractive cause before acting on it is the only reason
the second fix landed on the right thing. See [[feedback_verify-causal-claims]].

Related: [[feedback_fixtures-hide-boundary-drift]] (a sample chosen to confirm
sits far from the edge), [[feedback_default-permit-is-fail-open]] (what happens
to the instances nobody classified).
