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
