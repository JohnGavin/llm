# Secrets migration: launchd global setenv → per-job `with-secrets` (#791, #615)

## Background

`.claude/scripts/load-secrets` (run at login by `com.johngavin.load-secrets`)
sources `~/.config/secrets.env` and loops `launchctl setenv "$k" "$v"` for every
key it finds. `launchctl setenv` writes into the **GUI-domain** launchd
environment — every launchd job, and every GUI-launched process on the
machine, inherits those keys. Any process can read them back with
`launchctl print gui/$UID/<any-job-label>` (or `launchctl getenv KEY`). That is
the leak (#615).

The fix (#791) is `.claude/scripts/with-secrets` (symlinked at
`~/.local/bin/with-secrets`): it sources `~/.config/secrets.env` into ONE
process and `exec`s the real command, so secrets never touch the shared
launchd-domain environment. Each launchd job that actually needs a secret from
`~/.config/secrets.env` is wrapped individually; `load-secrets` /
`com.johngavin.load-secrets` are retired.

## Method

For every non-deprecated plist in `.claude/launchd/`: resolved
`ProgramArguments` to the script it runs, followed the script's own script
chain (wrapper → cron script → R/py payload), and grepped for:

- direct references to `OPENAI_API_KEY`, `GEMINI_API_KEY`, `GOOGLE_API_KEY`,
  `GITHUB_PAT`, `GH_TOKEN`, `HUGGING*`, `ELEVENLABS*`, `GUARDIAN_API*`,
  `GMAIL_*`
- email-send mechanisms (`smtp`, `mail(`, `blastula`, gmail helper scripts)
- `gh` invocations that might need a token beyond `gh`'s own stored
  authentication

A script only counts as **needs-secrets = yes** for this migration if it can
actually pull a value from `~/.config/secrets.env` via the launchd-inherited
environment — i.e. it either (a) has no dedicated per-job credentials file at
all, or (b) has one but explicitly falls back to "whatever is already in the
process environment" when that file is missing (the exact fallback path the
global `launchctl setenv` leak currently plugs). Scripts that source their
*own* dedicated file under `~/.claude/env/*.env` / `~/.claude/.env` with **no**
fallback-to-inherited-environment branch (they fail closed / dry-run instead)
are not coupled to the leak and are left unwrapped.

## Mapping

| Plist | Resolved script chain | Secret pattern found | needs-secrets |
|---|---|---|---|
| `com.claude.branch-gc.plist` | `branch_gc.sh` | none | no |
| `com.claude.capability-registry.plist` | `capability_registry_regen_cron.sh` | none | no |
| `com.claude.codex-overnight-learning.plist` | `codex_overnight_learning.py` | none | no |
| `com.claude.config-digest-email.plist` | `bin/config_digest_cron.sh` | `GMAIL_USERNAME`/`GMAIL_APP_PASSWORD`/`REPORT_RECIPIENT`; sources `~/.claude/env/roborev_email.env` **with fallback** "relying on existing environment" if absent | **yes** |
| `com.claude.cron-catchup.plist` | `cron_catchup.sh` | none | no |
| `com.claude.kb-digest-email.plist` | `bin/kb_digest_daily_cron.sh` | `GMAIL_USERNAME`/`GMAIL_APP_PASSWORD`/`REPORT_RECIPIENT`; sources `~/.claude/env/kb_digest.env` **with fallback** "relying on existing environment" if absent | **yes** |
| `com.claude.launchd-health-weekly.plist` | `bin/launchd_health_weekly_cron.sh` | `GMAIL_*` via `~/.claude/.env` + `~/.claude/env/roborev_email.env`; **no** fallback branch — job fails closed (R script aborts) if the dedicated files are absent | no |
| `com.claude.overnight-self-review-email.plist` | `bws_launcher.sh` → `bin/overnight_self_review_email_cron.sh` | `GMAIL_*` via `~/.claude/env/overnight_self_review.env` **with fallback** "relying on existing environment" if absent | **yes** |
| `com.claude.pr-status-pulse.plist` | `pr_status_pulse.sh` | none | no |
| `com.claude.roborev-agent-health.plist` | `roborev_agent_health.sh` | none | no |
| `com.claude.roborev-autoclose.plist` | `roborev_weekly_chain.sh` | none | no |
| `com.claude.roborev-bridge.plist` | `roborev_bridge_to_unified.sh` | none | no |
| `com.claude.roborev-daily-backlog.plist` | `roborev_daily_backlog_aggregator.sh` | none | no |
| `com.claude.roborev-daily-email.plist` | `bin/roborev_daily_cron.sh` | `GMAIL_USERNAME`/`GMAIL_APP_PASSWORD`/`REPORT_RECIPIENT`/`ROBOREV_DASHBOARD_URL`; sources `~/.claude/env/roborev_email.env` **with fallback** "relying on existing environment" if absent | **yes** |
| `com.claude.roborev-metrics-etl.plist` | `roborev_metrics_etl.sh` | none | no |
| `com.claude.roborev-poll-merges.plist` | `roborev_poll_merges.sh` | none | no |
| `com.claude.roborev-project-backlog.plist` | `roborev_project_backlog.sh` | none | no |
| `com.claude.roborev-severity-autoclose.plist` | `roborev_severity_autoclose.sh` | none | no |
| `com.claude.roborev-weekly-rollup-email.plist` | `bin/roborev_weekly_rollup_cron.sh` | `GMAIL_*` via `~/.claude/env/roborev_email.env`; **no** fallback — sets `EMAIL_DRY_RUN=1` and logs "no credentials file" instead of using inherited env | no |
| `com.claude.self-review-stage1.plist` | `self_review_stage1.sh` | none | no |
| `com.claude.self-review-verify.plist` | `self_review_verify.sh` | `gh workflow run` (uses `gh`'s own stored auth, not `~/.config/secrets.env`) | no |
| `com.claude.unified-duckdb-backup.plist` | `unified_duckdb_backup.sh` | none | no |
| `com.claude.wiki-health-pulse.plist` | `wiki_health_check.sh` | none | no |
| `com.claude.worktree-gc.plist` | `worktree_gc.sh` | none | no |
| `com.johngavin.roborev-failure-alert.plist` | `roborev-failure-alert` (local signal-cli + osascript, no API keys) | none | no |
| `com.johngavin.load-secrets.plist` | `load-secrets` | this IS the leak mechanism — retired in Group 3, not wrapped | n/a |

## Result

4 plists wrapped with `with-secrets` (Group 2); the rest are left alone because
they either use no secrets or already source a dedicated per-job credentials
file with no fallback to the leaked global environment.

## Group 2 — wrapped plists + `plutil -lint` results

`with-secrets` was prepended as the first `ProgramArguments` element (program
+ original args kept after it) for:

| Plist | `plutil -lint` |
|---|---|
| `com.claude.config-digest-email.plist` | OK |
| `com.claude.kb-digest-email.plist` | OK |
| `com.claude.overnight-self-review-email.plist` | OK |
| `com.claude.roborev-daily-email.plist` | OK |

All other plists (needs-secrets = no / n/a in the table above) were left
unmodified.
