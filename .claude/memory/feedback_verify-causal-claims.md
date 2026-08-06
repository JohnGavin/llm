---
name: feedback_verify-causal-claims
description: Load-bearing facts get queried; the causal story connecting them is where errors hide — assert a cause, a date, or a blast radius only with a query behind it
metadata:
  type: feedback
---

When diagnosing, the individual facts usually get verified — counts, mechanisms,
file contents. The **narrative connecting them** does not, and that is where the
errors are. Treat "X caused Y", "this happened on date D", and "this affects
surfaces A, B, C" as claims requiring the same evidence as "the tests pass".

**Why:** four corrections in one session (llm#913, 2026-08-05), all the same
shape — a relationship asserted because it looked obvious, then falsified by one
query:

| Claim asserted | Query that falsified it |
|---|---|
| "2,158 rows affected" | `SELECT count(*)` → 2033/2003; I had summed daily counts by hand |
| "email, dashboard and vignettes all affected" | grep for the column → email never reads it; vignette uses a different source |
| "PR #809's merge is the onset" | `max(started_at) WHERE duration_min <> 120.0` → break precedes the merge by ~4h |
| "window is closed, 0 affected today" (in a fix for this very bug) | reaper only marks after >6h → 33 affected rows sat outside the window |

The last one is the tell: the *fix* for an absence-of-evidence bug shipped the
same error one layer down. Plausibility is not evidence, and being mid-way
through fixing this exact failure mode is no protection against repeating it.

**Third layer, found 2026-08-06.** Row 3's correction was itself only half
right. "The break precedes the merge by ~4h" was query-backed and stands; the
*explanation* shipped alongside it — "the gating change was evidently live from
a local branch before the PR merged" — was pure inference, and is false. Three
queries kill it: `~/.claude/hooks` is a symlink to the main checkout so hooks
resolve nowhere else; that checkout's `git reflog` shows HEAD frozen from
2026-07-22 09:35 to the ff-pull at 2026-07-24 10:34; and 103 affected sessions
ran before that pull. Nothing under version control changed across the onset at
all — the trigger is still unidentified.

The lesson is narrower and nastier than "verify causes": **an explanation
attached to a verified fact inherits the fact's credibility without earning
it.** The reader (and the writer) sees one sentence carrying a timestamp and a
`WHERE` clause and waves the whole thing through. Split them — state the
queried fact, then state the explanation separately and mark it inferred, or
run the query that would falsify it. Preferring "trigger unidentified" over a
tidy story is the correct output, not a failure to finish the analysis.

**How to apply:**

- Before writing a causal sentence, name the query that would falsify it and run
  it. Onset claims are the worst offenders — adjacent dates read as causation.
  Verify the *transition* falls where the cause is, don't infer it from a merge
  timestamp or a changelog entry.
- Before naming affected surfaces, grep for the actual symbol. Do not reason
  from "this is a duration column so the duration report must use it".
- Derive boundaries from a source that cannot lag. A marker written by a
  *delayed* process (a reaper, a nightly sweep, a cron) understates the present:
  "nothing marked recently" means "not yet processed", not "not affected".
- Separate what is proven from what is inferred when reporting. Say which
  queries back which claims, so a reader knows what to re-check.
- A number retyped from prose into code or config is unverified by construction
  — re-derive it at the point of use (see the reproducible-ingestion rule).

Related: [[feedback_verify-external-claims]] (same discipline, external tools),
[[probe-must-not-share-writer-path]] (the bug this was learnt on),
[[deploy-gap-stale-main-checkout]]
