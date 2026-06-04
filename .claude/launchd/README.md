# launchd jobs

User-level macOS launch agents for scheduled maintenance. These are the
canonical, version-controlled copies; the live copies live at
`~/Library/LaunchAgents/<label>.plist`.

## Convention

- File name: `<label>.plist` where `label` matches the `<key>Label</key>` value.
- Programs referenced by absolute path (the agent runs outside any shell).
- Stdout/stderr go to `~/.claude/logs/<short-name>.{out,err}`.
- `RunAtLoad = false` — only fire on the scheduled interval, not at boot/load.

## Installed jobs

| Label | Schedule | What it does |
|---|---|---|
| `com.claude.roborev-autoclose` | Weekly, Mon 09:15 | Closes roborev review findings older than 30 days. See `.claude/scripts/roborev_autoclose.sh`. Tracked in #138. |
| `com.claude.pr-status-pulse` | Daily 09:30 / 12:30 / 16:30 | Logs open PR + CI status across tracked repos to `~/.claude/logs/pr_status.log`. Part of #137 Phase 4. |
| `com.claude.wiki-health-pulse` | Daily 09:45 | Runs `wiki_health_check.sh` against the local knowledge wiki. Part of #137 Phase 4. |
| `com.claude.codex-overnight-learning` | Daily 06:10 | Scans recent Codex sessions and writes a nightly learning digest to `~/.codex/learning/`. Startup surfacing comes from `.claude/scripts/codex-start.sh`. Tracked in #231. |
| `com.claude.overnight-self-review-email` | Daily 06:30 | Queries unified.duckdb for 24h deltas across 4 ETL source tables (sessions, agent_runs, hook_events, errors); sends collapsible HTML digest surfacing stale/dead tables and new self-review findings. Part of #491. |

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
