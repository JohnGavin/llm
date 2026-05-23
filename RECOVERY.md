# RECOVERY.md — llm project

Per the `backup-architecture` rule: this file documents the non-reproducible state
in this project, where backups live, and how to restore them.

**Owner:** John Gavin
**Last drill date:** Not yet performed — run quarterly restore test after first backup completes.

---

## Non-Reproducible State

| Asset | Path | Size | Why irreplaceable |
|---|---|---|---|
| `unified.duckdb` | `~/.claude/logs/unified.duckdb` | ~123 MB | Operational telemetry since 2026-01-10; financial cost records ($49K+); session history; roborev metrics. Cannot be regenerated — data is created at runtime. |

All other state in this project is reproducible from git + `tar_make()` / `quarto render`.

---

## Backup Details

| Field | Value |
|---|---|
| Backup location | `~/Dropbox/Backups/unified_duckdb/` (override via `BACKUP_ROOT` env var) |
| Failure domain | Dropbox (Dropbox servers + paired devices — different from laptop disk) |
| Mechanism | DuckDB `EXPORT DATABASE` (Parquet, ZSTD) — WAL-safe consistent snapshot |
| Cadence | Daily at 03:00 local time (one hour after roborev ETL at 02:00) |
| Retention — daily | 30 days |
| Retention — monthly | 12 months (1st-of-month export kept automatically) |
| Script | `~/.claude/scripts/unified_duckdb_backup.sh` |
| launchd plist | `~/.claude/launchd/com.claude.unified-duckdb-backup.plist` |

**RPO (Recovery Point Objective):** 24 hours
**RTO (Recovery Time Objective):** 15 minutes (sync from Dropbox + run restore commands)

---

## Backup Layout

```
~/Dropbox/Backups/unified_duckdb/
  2026-05-23/
    schema.sql         ← DDL for all tables
    agent_runs.parquet
    braindump_actions.parquet
    braindumps.parquet
    costs.parquet
    errors.parquet
    hook_events.parquet
    roborev_agent_performance.parquet
    roborev_cadence_efficacy.parquet
    roborev_daily_metrics.parquet
    roborev_review_lifecycle.parquet
    roborev_threshold_changes.parquet
    sessions.parquet
  2026-05-22/
    ...
```

---

## Install / Activate Backups

After deploying the script (first-time setup):

```bash
# 1. Copy plist to LaunchAgents
cp ~/.claude/launchd/com.claude.unified-duckdb-backup.plist \
   ~/Library/LaunchAgents/com.claude.unified-duckdb-backup.plist

# 2. Load it (starts scheduling — does not run immediately)
launchctl load ~/Library/LaunchAgents/com.claude.unified-duckdb-backup.plist

# 3. Verify it is scheduled
launchctl list | grep unified-duckdb-backup

# 4. Run a dry-run to confirm the script works
~/.claude/scripts/unified_duckdb_backup.sh --dry-run

# 5. Run a manual apply to create the first backup immediately
~/.claude/scripts/unified_duckdb_backup.sh --apply
```

---

## Restore Procedure

### Step 1 — Identify the backup to restore from

```bash
ls -la ~/Dropbox/Backups/unified_duckdb/
```

Choose the most recent date directory, e.g. `2026-05-23`.

### Step 2 — Verify backup integrity

```bash
# Count the parquet files — should match the number of tables in unified.duckdb
ls ~/Dropbox/Backups/unified_duckdb/2026-05-23/*.parquet | wc -l
# Expected: 12
```

### Step 3 — Move or rename the corrupted/lost DB (if it still exists)

```bash
# Move aside the corrupted file
mv ~/.claude/logs/unified.duckdb \
   ~/.claude/logs/unified.duckdb.$(date +%Y%m%d_%H%M%S).corrupted
```

### Step 4 — Restore into a new DB

```bash
# Open a new empty DuckDB and import from the backup
duckdb ~/.claude/logs/unified.duckdb

-- Inside the duckdb prompt:
IMPORT DATABASE '/Users/johngavin/Dropbox/Backups/unified_duckdb/2026-05-23';
.quit
```

### Step 5 — Verify restore consistency

Run the following row-count verification queries against the restored DB:

```bash
duckdb ~/.claude/logs/unified.duckdb -c "
SELECT
  table_name,
  estimated_size AS row_count
FROM duckdb_tables()
ORDER BY table_name;
"
```

Expected row counts (as of 2026-05-23, update this table quarterly):

| Table | Rows at last drill |
|---|---|
| `agent_runs` | 48 |
| `braindump_actions` | 33 |
| `braindumps` | 31 |
| `costs` | 85 |
| `errors` | 1 |
| `hook_events` | 1 |
| `roborev_agent_performance` | 4 |
| `roborev_cadence_efficacy` | 2 |
| `roborev_daily_metrics` | 54 |
| `roborev_review_lifecycle` | 834 |
| `roborev_threshold_changes` | 28 |
| `sessions` | 423 |

Counts in the restored DB should be within a few rows of these values (the backup
may be up to 24h old; ETL runs once daily at 02:00).

### Step 6 — Spot-check financial data

```bash
duckdb ~/.claude/logs/unified.duckdb -c "
SELECT MIN(date), MAX(date), ROUND(SUM(total_cost), 2) AS total_usd
FROM costs;
"
# Expected: date range 2026-01-10 to recent, total ~$49K+
```

### Step 7 — Resume normal operations

No further steps needed. The launchd backup agent will continue writing new daily
backups to iCloud Drive automatically.

---

## Quarterly Restore Drill

Run quarterly to verify backups are valid:

```bash
# Restore to a temp location
duckdb /tmp/unified_restore_test.duckdb -c \
  "IMPORT DATABASE '/Users/johngavin/Dropbox/Backups/unified_duckdb/$(ls ~/Dropbox/Backups/unified_duckdb/ | tail -1)'"

# Verify counts
duckdb /tmp/unified_restore_test.duckdb -c \
  "SELECT table_name, estimated_size FROM duckdb_tables() ORDER BY table_name"

# Clean up
rm /tmp/unified_restore_test.duckdb

# Update the "Last drill date" at the top of this file
```

---

## Troubleshooting

### Backup job not running

```bash
# Check if loaded
launchctl list | grep unified-duckdb-backup

# Check the log
tail -50 ~/.claude/logs/unified_duckdb_backup.log

# Run manually
~/.claude/scripts/unified_duckdb_backup.sh --apply
```

### iCloud not syncing

Ensure iCloud Drive is enabled in System Settings > Apple ID > iCloud > iCloud Drive.
Backups will accumulate locally and sync when iCloud is available (on next connection).

### Restore from partial backup (iCloud not synced)

If the laptop was lost before iCloud sync completed, the most recent backup may be
older than expected. In this case, restore from the most recent available backup and
accept the data loss for the period since that backup.

### DuckDB version mismatch

If the duckdb binary version differs from the version that wrote the backup, the
`IMPORT DATABASE` command may fail. In that case:

```bash
# Check the duckdb version used by the backup (recorded in schema.sql)
head -5 ~/Dropbox/Backups/unified_duckdb/2026-05-23/schema.sql

# Install a matching duckdb version and retry
```

---

## Related

- `backup-architecture` rule — `~/.claude/rules/backup-architecture.md`
- Backup script — `~/.claude/scripts/unified_duckdb_backup.sh`
- launchd plist — `~/.claude/launchd/com.claude.unified-duckdb-backup.plist`
- Plan document — `plans/228-unified-duckdb-backup.md`
- Issue — https://github.com/JohnGavin/llm/issues/228
