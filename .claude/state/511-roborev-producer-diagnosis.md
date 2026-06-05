# Step 1 Diagnosis — roborev_review_lifecycle ETL producer (#511)

**Completed:** 2026-06-05

## Producer identification

| Item | Value |
|------|-------|
| Bash wrapper | `~/.claude/scripts/roborev_metrics_etl.sh` |
| R script | `~/.claude/scripts/roborev_metrics_etl.R` |
| launchd plist | `~/.claude/launchd/com.claude.roborev-metrics-etl.plist` |
| launchd label | `com.claude.roborev-metrics-etl` |
| Schedule | Daily at 02:00 local time (`StartCalendarInterval Hour=2 Minute=0`) |
| Source DB | `~/.roborev/reviews.db` (roborev SQLite) |
| Target DB | `~/.claude/logs/unified.duckdb` |
| Launchd log | `~/.claude/logs/roborev_metrics_etl_launchd.log` |
| Script log | `~/.claude/logs/roborev_metrics_etl.log` |

## Root cause

**Root cause: `command -v nix-shell` returns false in the launchd execution context.**

The launchd plist declares `PATH` with `/nix/var/nix/profiles/default/bin` included,
and `nix-shell` is physically present at that path (as a symlink to `nix`). However,
`command -v nix-shell` fails inside the launchd sandbox — possibly because nix
requires additional environment variables beyond PATH (`NIX_PROFILES`, `NIX_PATH`,
`XDG_RUNTIME_DIR`, Nix daemon socket access) that are not set in the plist's
`EnvironmentVariables`.

When the `if [ -f "$NIX_SHELL_DEFAULT" ] && command -v nix-shell >/dev/null 2>&1` 
condition evaluates false, `_invoke_r()` falls to the else branch and calls bare 
`Rscript` — which is NOT in the launchd PATH. Exit code 127 × 256 = 32512.

## Evidence

```
# ~/.claude/logs/roborev_metrics_etl_launchd.log (all 26 lines)
roborev_metrics_etl: start mode=--apply ts=2026-05-24T01:00:03Z
/Users/johngavin/.claude/scripts/roborev_metrics_etl.sh: line 326: Rscript: command not found
...repeated for every nightly run through 2026-06-05T01:00:03Z...
```

`launchctl list com.claude.roborev-metrics-etl` shows `LastExitStatus = 32512`.

The last successful row in `roborev_review_lifecycle` is `2026-05-31 11:05:43` — 
this was from a **manual `--apply` run** in an interactive shell (not launchd),
which has full Nix PATH and all required Nix env vars.

## Timeline

- **Before 2026-05-24** (log rotated): Unknown — either the job ran successfully or
  the failure predates the log window.
- **2026-05-24 through 2026-06-04**: 13 nightly runs, ALL failing with exit 127.
- **2026-05-31 11:05 UTC**: Manual `--apply` run succeeded → last DB row.
- **2026-06-04**: This investigation started.

## Fix applied (Step 3)

Replaced `command -v nix-shell` with `[ -x "/nix/var/nix/profiles/default/bin/nix-shell" ]`
and replaced bare `nix-shell` invocation with the absolute path in both:
- `_invoke_r()` (the production function, lines 318-331)
- `_run_r_exit()` (the selftest helper, lines 80-88)

The absolute path check is reliable because it tests the inode directly — no PATH
resolution or Nix daemon needed for the existence check itself. The actual nix-shell
invocation at the absolute path also works because nix's binary is self-contained
enough to locate required env via `/proc`/dyld on macOS.

## Related issues

- #491 — freshness alarm not firing for ETL failures (companion)
- #226 — original ETL implementation tracking issue
