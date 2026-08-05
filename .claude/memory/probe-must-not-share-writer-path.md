---
name: probe-must-not-share-writer-path
description: "A freshness/health probe that runs on the same code path as the writer it measures reports its own liveness, not the data's — so a healthy asset reads as dead, and a dead one can read as fine"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 796b4022-005c-4351-842a-1a0238e35c55
  modified: 2026-08-05T16:31:40.392Z
---

A monitoring probe MUST be able to observe its asset independently of the code
that produces that asset. When the probe is a call sitting *inside* the writer's
code path, it stops reporting on the data and starts reporting on itself.

**Why:** the failure is bidirectional and both directions are silent.

- *Writer dies, data fine* — llm#913, 2026-08-05. `etl_freshness_upsert.sh sessions`
  was called from exactly one place: the `stop` case of `log_session.sh`. When a
  sentinel race (llm#915) killed that path on 2026-07-24, the heartbeat froze at
  2026-07-23 while the `sessions` table kept taking 300+ rows/day. The registry
  reported "13 days idle"; one `SELECT count(*)` showed 327 rows on 2026-08-03.
  The whole issue was filed against the wrong cause.
- *Writer fine, data dead* — the mirror case. The probe fires happily on every
  run and reports fresh, because running is all it actually measures.

A stored `status` column makes this strictly worse: it can only change when the
writer successfully runs, so a push-based registry with stored status cannot
detect the *absence* of a write at all. Compute status at read time from facts
(llm#893's `staleness_status` view), and give the probe a path to the asset that
does not route through the producer.

**How to apply:** when adding or reviewing a freshness/health check, ask "what
does this actually observe — the data, or the fact that some code ran?" If the
probe call lives inside the producer, move it out: read the asset directly
(`MAX(ts)` on the table, file mtime, row count) from a separate trigger class.
Prefer a different trigger class for the reader too — llm#893's collector is
read at session start precisely because every prior checker was itself a launchd
job, so a total launchd outage silenced the monitor along with everything it
watched (llm#886).

Corollary when triaging: if a freshness registry says a source is idle, confirm
against the source before trusting the registry — especially when the registry
is the thing under suspicion.

Related: [[deploy-gap-stale-main-checkout]], [[roborev-gemini-dead-silent-failure]],
[[feedback_verify-external-claims]]
