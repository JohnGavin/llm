# Companion: Long-Running Process Supervision — Incident Narratives

Dated incident narrative split out of the always-loaded
[`long-running-process-supervision`](../long-running-process-supervision.md)
rule to keep it under the rules size limit. The normative content (the
Three-Part Invariant, Reference Implementation, Forbidden Patterns, and the
"establish two facts before migrating" table) stays in the rule — none of it
depends on this file. This file is the full llm#936 incident narrative and
the dated resolution history, kept for audit trail.

## llm#936 — the 7-day stale-secret incident, in full

[llm#936](https://github.com/JohnGavin/llm/issues/936) — the roborev review
daemon self-daemonized via `roborev daemon start` (fork, detach, return a
shell prompt). Nothing then owned its lifecycle. It ran 7 days holding a
stale `GEMINI_API_KEY` after a rotation, every review failed the whole time,
and nothing detected it: no restart, no age bound, no health check coverage.
[llm#956](https://github.com/JohnGavin/llm/issues/956) is the migration that
put it under launchd supervision (`com.roborev.daemon.plist` +
`roborev_daemon_launcher.sh`) and is the reference implementation for this
rule.

## Why the roborev orphan was never found by looking for an orphan

Many daemon-backed CLIs **auto-start a daemon from any client command** when
none is reachable — roborev does this from `stream`. The pre-migration
process was not an orphan from a hand-typed `daemon start` at all: it was a
child of `roborev stream`, itself a child of the `com.roborev.auto-refine`
launchd job. So the process was transitively supervised by the *wrong* job,
which is why a restart of that job appeared to fix llm#936 and why nothing
looked like an orphan when someone went looking for one. This is the reason
the rule's migration checklist insists on tracing the actual parent process
chain (`ps -o pid,ppid,lstart,command` up to PPID 1) rather than trusting
that "nothing is running `daemon start`" means nothing self-daemonized.

## `kind: daemon` consumer type — retained after its only user migrated

`CONSUMERS_GEMINI_API_KEY` became
`launchd:com.roborev.auto-refine launchd:com.roborev.daemon` when
`com.roborev.daemon` was installed and verified (2026-08-14); the
`kind: daemon` consumer type (in `secrets-single-source`'s consumer map)
that existed only to reach the unsupervised process now has no users. The
type itself is kept in `lib/secret_consumers.sh` — it is the correct
mechanism for any *future* unsupervised consumer found before it can be
migrated, and deleting it would mean the next such discovery has nowhere to
be recorded.
