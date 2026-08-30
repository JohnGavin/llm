# Companion: Long-Running Process Supervision — Client-Spawns-Daemon Incident Detail

Dated incident detail split out of the always-loaded
[`long-running-process-supervision`](../long-running-process-supervision.md)
rule to keep it under the repo's line-count budget. The normative content
(Source, CRITICAL statement, the Three-Part Invariant, Reference
Implementation, Forbidden Patterns, the two-question table + conclusion for
"A Client Can Spawn the Daemon", Known Follow-Up, Related) stays in the
rule; this file is the full llm#936 grandchild-process narrative and the
race-condition explanation, loaded on demand.

## Why the llm#936 process looked orphan-free

Installing the plist is not sufficient on its own. Many daemon-backed CLIs
**auto-start a daemon from any client command** when none is reachable —
roborev does this from `stream`, and the pre-migration process was not an
orphan from a hand-typed `daemon start` at all: it was a child of
`roborev stream`, itself a child of the `com.roborev.auto-refine` launchd
job. So the process was transitively supervised by the *wrong* job, which is
why a restart of that job appeared to fix llm#936 and why nothing looked like
an orphan when someone went looking for one.

## Why stop the spawning job first

Then stop the **spawning job first**, not the daemon first. Killing the
daemon while its client keeps running just hands the port to a fresh rival.

## The single-binder-lock race, in full

A single-binder lock bounds the race but does not remove it: while a
client-spawned rival holds the port, the launchd copy fails to bind, exits,
and is held off by `ThrottleInterval` before retrying — so a rival can own
the queue for up to that interval. Supervision is not a substitute for
knowing what else starts the process.
