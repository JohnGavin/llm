---
description: Anything long-running is a launchd job — never self-daemonized, never started by hand; every such job needs both log paths and a visible age metric
paths:
  - ".claude/launchd/**"
  - ".claude/scripts/**"
  - "bin/**"
---

# Rule: Long-Running Processes Are launchd Jobs (No Self-Daemonizing)

## Source

[llm#936](https://github.com/JohnGavin/llm/issues/936) — a self-daemonized
roborev review process ran 7 days holding a stale `GEMINI_API_KEY` after a
rotation, every review failed the whole time, and nothing detected it: no
restart, no age bound, no health check coverage. Full incident narrative is
in the companion. [llm#956](https://github.com/JohnGavin/llm/issues/956) is
the migration that put it under launchd supervision
(`com.roborev.daemon.plist` + `roborev_daemon_launcher.sh`) and is the
reference implementation for this rule.

## When This Applies

Any time a script, tool, or CLI would otherwise be started once and left
running indefinitely — a review daemon, a stream listener, an event-driven
worker, anything whose own `--help` offers a `start`/`daemon` mode that
forks and detaches.

## CRITICAL: launchd Owns Every Long-Running Process — Nothing Self-Daemonizes

> Anything long-running is a launchd job. Nothing is started by hand or
> self-daemonized.

A process that forks itself into the background escapes every supervision
mechanism this project has: launchd's `KeepAlive` never sees it (there is no
launchd job to restart), the weekly `launchd_health_audit.sh` never sees it
(it audits installed plists, not ad hoc PIDs), and it never appears in a
`launchctl list`-based inventory. The only thing keeping it alive is the fact
that it happens to still be running — which is also true right up until the
moment it silently stops being useful (stale credentials, stale config, a
crash nobody saw) while its PID keeps existing.

## The Three-Part Invariant

Every long-running process MUST satisfy all three, not just the first:

### 1. launchd owns the lifecycle

`RunAtLoad = true` + `KeepAlive = true` in a versioned plist under
`.claude/launchd/`. The plist's `ProgramArguments` MUST point at a wrapper
that runs the real work in the **foreground** — never at a subcommand that
itself forks and detaches (e.g. `<tool> start`, `<tool> daemon start`). If
the underlying tool only has a self-daemonizing entrypoint, write a launcher
script that calls its **foreground** variant (`<tool> run`, `<tool> daemon
run`, or equivalent) via `exec`, so the forked process launchd is watching
and the process actually doing the work are the same PID. `exec`, not a
background `&` — a backgrounded child inside the launcher reintroduces the
exact "parent exits, nobody supervises the real process" failure this rule
exists to close.

Corollary: secrets and config MUST be re-read fresh by the launcher on
**every** start launchd performs — RunAtLoad and every KeepAlive
restart — never captured once by a long-lived process that then outlives
every subsequent rotation. See `secrets-single-source` for the sourcing
pattern (`set -a; . "$SECRETS_ENV_FILE"; set +a`) and its own account of the
llm#936 incident from the credential side.

### 2. Both log paths are set

`StandardOutPath` AND `StandardErrorPath`, both under `~/.claude/logs/`.
Already MANDATORY per `housekeeping-framework` for scheduled tasks; doubly
critical here because a perpetual process has no other output channel a
human will ever see — there's no cron-run digest line, no session-init
banner, just whatever launchd captured.

### 3. An age metric is visible somewhere in the health surface

Supervision alone (restart-on-crash) does not bound how long a
**healthy-looking** process can run while holding a stale environment. A
process that never crashes never gets restarted, so its age is unbounded by
`KeepAlive` alone. Something in the existing health-check rotation MUST
report process uptime and flag it past a threshold — prefer extending an
existing periodic check (ps-based PID lookup + `ps -o etime=`) over adding a
new scheduled job for this alone. The reference implementation extends
`roborev-failure-alert` (already runs every 30 min, already does daemon
liveness detection) rather than adding a sixth roborev launchd job.

**The age metric is visibility, not an automatic restart.** A scheduled
unconditional restart would have made the llm#936 symptom vanish every
morning and reappear every evening, with the cause never identified —
bounding the damage must not erase the evidence. The age check logs and
notifies; a human decides whether the situation (e.g. a secret rotated since
the process started) warrants `launchctl kickstart`.

## Reference Implementation

- `.claude/scripts/roborev_daemon_launcher.sh` — sources secrets fresh, fails
  loud (`exit 78`) if a required secret is absent, `exec`s the daemon's
  foreground subcommand.
- `.claude/launchd/com.roborev.daemon.plist` — `RunAtLoad`/`KeepAlive` true,
  both log paths, `ThrottleInterval` to bound a crash-loop, PATH copied from
  the sibling `com.roborev.auto-refine.plist` (known-working PATH for
  resolving the `codex`/`gemini` review-agent binaries). Header comment
  carries the full install/verify/rollback sequence.
- `.claude/scripts/roborev-failure-alert` — extended with a daemon-age block
  (`pgrep` + `ps -o etime=`, own dedup state file so it can't corrupt the
  pre-existing 3-field state parse) rather than a new script.

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---|---|---|
| Plist `ProgramArguments` points at a self-daemonizing `start` subcommand | launchd sees the parent exit immediately; the actual worker is an orphan it never supervises | Wrapper launcher that `exec`s the tool's foreground/`run` variant |
| Launcher backgrounds the real work with `&` then exits | Same failure as above, one layer deeper | `exec`, never background, inside the launcher |
| Plist missing `StandardOutPath` or `StandardErrorPath` | Errors from a process nobody is watching interactively vanish completely | Always set both, under `~/.claude/logs/` |
| No age metric anywhere in the health surface | A stale-but-alive process is indistinguishable from a healthy one until something downstream fails | Extend an existing periodic check with a `ps`-based uptime + threshold |
| A scheduled unconditional restart used as the "fix" for staleness | Erases the evidence of *why* it went stale; the next occurrence is invisible again | Age check is advisory/visible only — restart is a human decision |
| Secrets sourced once at daemon startup by a parent shell that then runs for days | Silently stale after any rotation until something else happens to restart it | Launcher re-sources on every launchd-triggered start, which happens on every crash-restart and reboot |
| Telling an operator to run `<tool> daemon start` when the daemon fires "not running" | Recreates the self-daemonizing process this rule removed | Point at `launchctl kickstart -k gui/$(id -u)/<label>` instead |

## A Client Can Spawn the Daemon You Are Trying to Supervise

Installing the plist is not sufficient on its own. Many daemon-backed CLIs
**auto-start a daemon from any client command** when none is reachable — see
the companion for the roborev case where this meant the "orphan" was never
found by looking for an orphan.

Before migrating, establish two facts about the tool:

| Question | How to answer it | Why it matters |
|---|---|---|
| What actually spawns the running process? | `ps -o pid,ppid,lstart,command` up the PPID chain until PPID 1 | A "self-daemonized orphan" may in fact be a grandchild of another job; killing the process alone lets its parent respawn it |
| Is there a single-binder lock? | `lsof -nP -p <pid> -a -i` / `-a -U` | A fixed port or socket bounds the damage: a rival cannot bind and exits. Without one, two daemons can serve the same queue indefinitely |

Then stop the **spawning job first**, not the daemon first. Killing the
daemon while its client keeps running just hands the port to a fresh rival.

A single-binder lock bounds the race but does not remove it: while a
client-spawned rival holds the port, the launchd copy fails to bind, exits,
and is held off by `ThrottleInterval` before retrying — so a rival can own
the queue for up to that interval. Supervision is not a substitute for
knowing what else starts the process.

## Known Follow-Up (Not This Change)

None outstanding. See the companion for why the `kind: daemon` consumer type
in `secrets-single-source`'s map is retained even though its only user
migrated to `launchd:`.

## Related

- [`_companions/long-running-process-supervision-details.md`](_companions/long-running-process-supervision-details.md)
  — full llm#936 incident narrative and the `kind: daemon` retention rationale
- `secrets-single-source` — the credential-freshness half of the same
  incident; `kind: daemon` consumer type this rule's migration obsoletes
- `housekeeping-framework` — the sibling framework for *scheduled* tasks
  (cron/launchd-interval); this rule covers *perpetual* (`KeepAlive`)
  processes, a distinct category with its own age-metric requirement
- `roborev-resolution` — day-to-day roborev workflow; unaffected by this
  change, which only touches how the daemon process itself is supervised
- `.claude/scripts/roborev_agent_health.sh` — a second roborev launchd job
  that already does `launchctl bootout`/`bootstrap` kickstarts; a model for
  "restart via launchd, never by hand" once this migration lands
- llm#936 — the 7-day stale-secret incident
- llm#956 — this migration
