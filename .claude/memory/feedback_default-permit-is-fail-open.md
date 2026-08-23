---
name: feedback_default-permit-is-fail-open
description: Any publish/exclude mechanism built as an opt-out enumeration is fail-open — new items are exposed by default until someone remembers
metadata: 
  node_type: memory
  type: feedback
  originSessionId: f2ceb4a5-18a9-47e4-95c0-1bb159694960
  modified: 2026-08-22T21:45:14.346Z
---

A privacy or publication control expressed as a **list of things to exclude** is
fail-open. Everything not yet named is published. Nothing announces the omission,
so the failure is silent and grows with every new project.

**Why:** two separate leaks in one day, same shape.

- `llmtelemetry` published ~584 rows of `premortem` (estate/personal-finance)
  session data from 26 May. `R/privacy_exclusion.R` existed and *worked*;
  premortem was simply never added to it. The filter was not broken — the
  default was.
- A personal phone number sat in the public `llm` repo for four months. The
  controls were advisory rules and issues; nothing denied by default.

Both are the same failure: **default-permit, opt-out, no gate.** The value-level
gates built in llm#946 fix leaked *values*; they do not fix a pipeline whose
default is to publish.

Note the exposure was not a secret. It was a project *name*, timestamps, costs,
and institution names (Wise, Marcus, RBS in llm's public `AGENTS.md`). No
balance or account number leaked. "The name alone discloses the subject" —
so scanning for credential-shaped strings would never have caught it.

**How to apply:**

1. When you meet any publish/export/dashboard pipeline, ask **"what happens to a
   thing nobody classified?"** If the answer is "it ships", that is the bug —
   independent of whether anything has leaked yet.
2. Invert to an **allow-list**: publish only what is explicitly marked
   publishable. An unclassified project must fail closed, loudly.
3. Treat *names, paths, timestamps and institutions* as disclosive, not just
   values. Ask what an inference-minded reader learns from the metadata alone.
4. Do not accept "the filter works" as an answer. Ask what the filter's default
   is for an input it has never seen.

Related: [[feedback_visibility-change-beats-history-surgery]],
[[feedback_verify-causal-claims]], [[probe-must-not-share-writer-path]].
Origin: llm#946, llmtelemetry#347, 2026-08-22.
