---
paths:
  - ".claude/rules/long-running-process-supervision.md"
---

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

## 2026-09-14 → 09-24: launchd's roborev daemon never held its port (llm#1136, llm#984 item 4)

`~/.claude/logs/roborev-daemon.log` shows launchd's `com.roborev.daemon`
failing every ~60s with `daemon already running (pid N)`, across three
distinct orphan pids over a ten-day window: pid 21182 (started 09-14), pid
89460 (09-14 22:00 through 09-23 20:46, spawned by a `roborev stream` call),
and pid 27294 (09-23 20:47 through 09-24 16:27, started from an interactive
shell — `XPC_SERVICE_NAME=0`, with the full shell PATH including homebrew).
Nothing alerted for those ten days.

Why this happened: every roborev client auto-starts a daemon when none is
reachable, and there is no global switch to suppress this (`--no-daemon`
exists only on `roborev init`). launchd's `KeepAlive` retries roughly once a
minute, so whichever client process happens to start first after any daemon
exit wins the race and becomes the long-lived daemon — not launchd's own
copy.

Consequence observed: the orphan daemon carried a homebrew-inclusive PATH,
which let it keep spawning `agentsview serve` — the same problem llm#1136
was opened to fix.

Remediation sequence that actually cleared it: `launchctl bootout` the
`com.roborev.auto-refine` job first (it is the client that keeps
respawning a rival daemon), kill the orphan daemon process, then
`launchctl bootout` followed by `bootstrap` on `com.roborev.daemon`, then
verify the listener on port 7373 belongs to launchd's own copy (`ps eww` on
the pid holding the port should show `XPC_SERVICE_NAME=com.roborev.daemon`,
not `0` or a shell-inherited value), and only then `bootstrap` the
`com.roborev.auto-refine` job again.

Gotcha: `launchctl kickstart -k` restarts a job using the plist definition
that was cached at the job's last bootstrap — editing the plist file on
disk has no effect on an already-loaded job until it is booted out and
bootstrapped again.

Detection follow-up (not done here, separate PR): add a check to
`roborev-failure-alert` for "the process holding port 7373 is not
launchd's `com.roborev.daemon`", so a repeat of this incident pages instead
of sitting silent for ten days.
