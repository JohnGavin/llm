---
name: reference_roborev-job-id-vs-review-id
description: roborev show/close/comment take the JOB id (review_jobs.id), not reviews.id — pasting a review id closes an unrelated job
metadata:
  type: reference
---

The roborev CLI (`show`, `close`, `comment`) addresses **`review_jobs.id`** ("job id").
`reviews.id` is a different id space: review 9409 is job 12500, and `roborev show 9409`
returns an unrelated job.

**Resolve before acting** (read-only):
`sqlite3 -readonly ~/.roborev/reviews.db "SELECT id AS review_id, job_id, closed FROM reviews WHERE id IN (9507, 9508)"`
then `roborev comment <job_id> "..."` and `roborev close <job_id>`, and re-run the query to
confirm `closed=1` (a successful `close` call is not proof).

**Why:** the weekly rollup and daily email printed `reviews.id`, so the "Top Stuck Findings"
ids could not be used with the CLI (llm#1225 and llm#1230 changed the printed id to the job id,
header `Job`). Older reports, issue text and notes may still cite review ids.

**How to apply:** any id copied from a roborev report older than 2026-09-20 is a review id until
proven otherwise. Related: [[roborev-gemini-dead-silent-failure]].
