# Companion: Secrets Single Source — Incident Narratives and Extended Rationale

Dated incident narratives and verbose rationale split out of the
always-loaded [`secrets-single-source`](../secrets-single-source.md) rule to
keep it under the repo's line-count budget. The normative content
(Architecture, CRITICAL statements, Usage commands, the consumer-map
mechanism, Single-Source Check mechanism, Related) stays in the rule; this
file is the incident narratives and extended rationale, loaded on demand.

## The incident that motivates "never let secrets.env overwrite BWS"

`secrets.env` held `GMAIL_APP_PASSWORD` as a 21-character value — quotes
and spaces baked in by a bad prior migration. BWS already held the correct
16-character app password. Six cron email jobs depend on the BWS value. Had
`secrets_to_bws.sh` "helpfully" pushed the `secrets.env` value into BWS to
keep them in sync, it would have overwritten the correct credential with a
corrupted one and broken every wrapped job. The never-overwrite rule exists
so this class of accident is structurally impossible, not merely
discouraged.

## The 2026-08-13 restart-verification incident (llm#936)

`rotate_secret.sh --apply` and `rotate_gmail_password.sh --apply` restart
every known consumer of the secret they just rotated, and never trust
`launchctl kickstart`'s exit code as proof the restart happened. A
`KeepAlive` launchd job can return success from `kickstart -k` without
actually cycling — this is exactly what happened on 2026-08-13: the
`GEMINI_API_KEY` rotation restarted `com.roborev.auto-refine`, reported
"restarted", and exited 0, while the separate self-daemonized
`roborev daemon run` process — not a launchd job, invisible to
`launchctl kickstart` — kept running with the stale key for hours.

## Bringing a `daemon:` consumer under launchd — worked example

`CONSUMERS_GEMINI_API_KEY` listed `daemon:roborev` for exactly this reason
until `com.roborev.daemon` was installed and verified on 2026-08-14
(llm#956); both consumers are now `launchd:`, and the launcher re-sources
this cache on every start launchd performs, so a rotation reaches the
daemon by construction rather than by anyone remembering to list a second
consumer kind.

## `credential_single_source_check.sh` — full reuse rationale

It reuses `secret_exposure_scan.sh`'s NAME-shape heuristic (extracted at
runtime, not copy-pasted) and its `--json` output (detector 4, shelled out
to) rather than re-deriving either — see the script's own header comment for
the full reuse rationale, including why neither `secret_exposure_scan.sh`
nor `secrets_cache_regen.sh` could simply be `source`d (both run their main
flow unconditionally, including a live `bws` call in the latter's case).

## Known, expected `GMAIL_APP_PASSWORD` duplication finding

As of this script's introduction, a real run correctly reports
`GMAIL_APP_PASSWORD` as duplicated across `secrets.env` and the three
`~/.claude/env/*.env` files — this is a **known, expected** finding, not a
bug: collapsing those files is blocked pending rotation of that value (see
the GMAIL_APP_PASSWORD incident above). The check reports the fact; it does
not fix it.
