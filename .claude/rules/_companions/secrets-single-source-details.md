# Companion: Secrets Single Source — Incident Narratives

Dated incident narratives split out of the always-loaded
[`secrets-single-source`](../secrets-single-source.md) rule to keep it
under the rules size limit. The normative content (Architecture, the two
CRITICAL statements, `secrets_to_bws.sh`/`secrets_cache_regen.sh` usage, the
PID+start-time restart-verification requirement, and the consumer-map
contract) stays in the rule — none of it depends on this file. This file is
the two incidents that motivated those requirements, kept for audit trail.

## The GMAIL_APP_PASSWORD incident (motivates "never let secrets.env overwrite BWS")

`secrets.env` held `GMAIL_APP_PASSWORD` as a 21-character value — quotes
and spaces baked in by a bad prior migration. BWS already held the
correct 16-character app password. Six cron email jobs depend on the BWS
value. Had `secrets_to_bws.sh` "helpfully" pushed the `secrets.env` value
into BWS to keep them in sync, it would have overwritten the correct
credential with a corrupted one and broken every wrapped job. The
never-overwrite rule exists so this class of accident is structurally
impossible, not merely discouraged.

## The 2026-08-13 GEMINI_API_KEY restart-verification incident

`rotate_secret.sh --apply` and `rotate_gmail_password.sh --apply` restart
every known consumer of the secret they just rotated, and never trust
`launchctl kickstart`'s exit code as proof the restart happened. A
`KeepAlive` launchd job can return success from `kickstart -k` without
actually cycling — this is exactly what happened on 2026-08-13: the
`GEMINI_API_KEY` rotation restarted `com.roborev.auto-refine`, reported
"restarted", and exited 0, while the separate self-daemonized
`roborev daemon run` process — not a launchd job, invisible to
`launchctl kickstart` — kept running with the stale key for hours
(llm#936). This is the incident that motivates the PID + process-start-time
double-check both rotation scripts now perform before reporting a consumer
as restarted.

## `CONSUMERS_GEMINI_API_KEY` migration off `kind: daemon`

`CONSUMERS_GEMINI_API_KEY` listed `daemon:roborev` (the consumer kind that
reaches a process no `launchctl kickstart` can touch) until
`com.roborev.daemon` was installed and verified on 2026-08-14 (llm#956);
both consumers are now `launchd:`, and the launcher re-sources the secrets
cache on every start launchd performs, so a rotation reaches the daemon by
construction rather than by anyone remembering to list a second consumer
kind. See `long-running-process-supervision` for the migration, including
the measured finding that a roborev *client* auto-spawns a daemon when none
is reachable — so the spawning job must be stopped first.

## Why the consumer map lives in one shared file

The two rotation scripts previously carried byte-identical copies of the
consumer map and its restart/verify functions — the same drift risk one
layer up from the GMAIL_APP_PASSWORD incident above (a name in two places,
silently disagreeing). Moving both into
`.claude/scripts/lib/secret_consumers.sh` (llm#958), sourced by both
scripts, closed that gap; `rotate_secret.sh --selftest` now asserts every
`CONSUMERS_*` name is defined exactly once under `.claude/scripts/**`, so a
reintroduced duplicate fails the selftest rather than drifting invisibly.
