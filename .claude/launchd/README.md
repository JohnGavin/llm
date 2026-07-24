# launchd jobs

User-level macOS launch agents for scheduled maintenance. These are the
canonical, version-controlled copies; the live copies live at
`~/Library/LaunchAgents/<label>.plist`.

## Convention

- File name: `<label>.plist` where `label` matches the `<key>Label</key>` value.
- Programs referenced by absolute path (the agent runs outside any shell).
- Stdout/stderr go to `~/.claude/logs/<short-name>.{out,err}`.
- `RunAtLoad = false` — only fire on the scheduled interval, not at boot/load.

## Secrets convention: `with-secrets`, not global `setenv` (#791, #615)

Any job whose script needs a value from `~/.config/secrets.env` (or falls
back to the inherited process environment for one — see
`SECRETS_MIGRATION.md`) MUST be wrapped by prepending
`/Users/johngavin/.local/bin/with-secrets` as the **first**
`ProgramArguments` element, ahead of the real program:

```xml
<key>ProgramArguments</key>
<array>
    <string>/Users/johngavin/.local/bin/with-secrets</string>
    <string>/bin/bash</string>
    <string>/Users/johngavin/docs_gh/llm/bin/some_cron.sh</string>
</array>
```

`with-secrets` (`.claude/scripts/with-secrets`) sources
`~/.config/secrets.env` into that one exec'd process only — it never touches
the shared launchd GUI-domain environment, so `launchctl print
gui/$UID/<any-job>` cannot leak the values into unrelated processes.

Do NOT reach for the old `launchctl setenv`-loop pattern
(`com.johngavin.load-secrets`, retired) — it pushed every key from
`~/.config/secrets.env` into the domain-wide environment, readable by any
process on the machine as the same user. See `SECRETS_MIGRATION.md` for the
full plist-by-plist mapping and `.claude/scripts/verify_no_launchd_secret_leak.sh`
for the post-apply check.

## Installed jobs

| Label | Schedule | What it does |
|---|---|---|
| `com.claude.roborev-autoclose` | Weekly, Mon 09:15 | Closes roborev review findings older than 30 days. See `.claude/scripts/roborev_autoclose.sh`. Tracked in #138. |
| `com.claude.pr-status-pulse` | Daily 09:30 / 12:30 / 16:30 | Logs open PR + CI status across tracked repos to `~/.claude/logs/pr_status.log`. Part of #137 Phase 4. |
| `com.claude.wiki-health-pulse` | Daily 09:45 | Runs `wiki_health_check.sh` against the local knowledge wiki. Part of #137 Phase 4. |
| `com.claude.codex-overnight-learning` | Daily 06:10 | Scans recent Codex sessions and writes a nightly learning digest to `~/.codex/learning/`. Startup surfacing comes from `.claude/scripts/codex-start.sh`. Tracked in #231. |
| `com.claude.overnight-self-review-email` | Daily 06:30 | Queries unified.duckdb for 24h deltas across 4 ETL source tables (sessions, agent_runs, hook_events, errors); sends collapsible HTML digest surfacing stale/dead tables and new self-review findings. Part of #491. |
| `com.claude.roborev-bridge` | Daily 06:00 | Read-only mirror of roborev SQLite (`~/.roborev/reviews.db`) → unified.duckdb::roborev_daily_summary. #555/#580. |

## Retired jobs

| Label | Retired | Why | Coverage now |
|---|---|---|---|
| `com.claude.stage1-findings-email` | 2026-06-07 | Redundant with 06:30 digest (#551) | The 06:30 `overnight-self-review-email` reads `self_review_findings_stage1` and surfaces the same severity breakdown + finding counts |
| `com.claude.capability-registry` | 2026-07-23 | Headless cron only regenerates the on-disk HTML; republishing the live claude.ai artifact needs a session (Artifact tool). No consumer of the on-disk file — half a job. | Regenerated + republished manually during a session when the registry is needed. |
| `com.johngavin.load-secrets` | 2026-07-23 | Pushed `~/.config/secrets.env` into the global launchd GUI-domain environment via `launchctl setenv` — readable by any process on the machine (#615) | Per-job `with-secrets` wrapping (see "Secrets convention" above and `SECRETS_MIGRATION.md`); `.claude/scripts/load-secrets` is now a no-op kept for historical reference only |

Retired plists are renamed `*.plist.deprecated-YYYY-MM-DD` (kept for rollback during the soak period — typically 2 weeks) before deletion.

After this retirement, orchestrators MUST unload the still-installed copy from `~/Library/LaunchAgents/`:

```bash
/bin/launchctl unload ~/Library/LaunchAgents/com.claude.stage1-findings-email.plist
rm ~/Library/LaunchAgents/com.claude.stage1-findings-email.plist
```

## Install / reload after editing

```bash
# Sync the canonical copy into LaunchAgents and reload:
cp .claude/launchd/com.claude.roborev-autoclose.plist \
   ~/Library/LaunchAgents/

/bin/launchctl unload \
  ~/Library/LaunchAgents/com.claude.roborev-autoclose.plist 2>/dev/null || true
/bin/launchctl load \
  ~/Library/LaunchAgents/com.claude.roborev-autoclose.plist

# Verify it loaded:
/bin/launchctl list com.claude.roborev-autoclose
```

## Uninstall (revert)

```bash
/bin/launchctl unload ~/Library/LaunchAgents/com.claude.roborev-autoclose.plist
rm ~/Library/LaunchAgents/com.claude.roborev-autoclose.plist
```

The script at `.claude/scripts/roborev_autoclose.sh` is unaffected — it
remains usable as a one-shot manual command.

## Run on-demand (without waiting for the schedule)

```bash
/bin/launchctl kickstart -k gui/$(id -u)/com.claude.roborev-autoclose
```
