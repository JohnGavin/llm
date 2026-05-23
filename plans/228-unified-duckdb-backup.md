# Plan: unified.duckdb Backup Strategy (#228)

**Issue:** https://github.com/JohnGavin/llm/issues/228
**Date:** 2026-05-23
**Status:** Implemented

---

## 1. What unified.duckdb Contains

`~/.claude/logs/unified.duckdb` is a 123 MB DuckDB file with 12 tables accumulating
irreplaceable operational telemetry since 2026-01-10. It is explicitly non-reproducible:
the data is generated in real time and no upstream source can regenerate it.

| Table | Rows | Date range | Value at risk |
|---|---|---|---|
| `sessions` | 423 | 2026-02-13 → present | Full session history with burn_status, duration, project |
| `roborev_review_lifecycle` | 834 | 2026-05-20 → present | PR review outcomes, escalation decisions |
| `costs` | 85 | 2026-01-10 → 2026-04-21 | $49,579.73 tracked LLM spend (financial record) |
| `roborev_daily_metrics` | 54 | 2026-05-20 → present | Daily roborev KPIs |
| `agent_runs` | 48 | — | Agent dispatch outcomes |
| `braindump_actions` | 33 | — | Braindump lifecycle (act/complete records) |
| `braindumps` | 31 | — | Raw braindump captures |
| `roborev_threshold_changes` | 28 | — | Severity threshold change history |
| `roborev_agent_performance` | 4 | — | Agent effectiveness metrics |
| `roborev_cadence_efficacy` | 2 | — | Cadence effectiveness snapshots |
| `hook_events` | 1 | — | Hook execution events |
| `errors` | 1 | — | Error log |

**Total:** 1,544 rows of irreplaceable operational data. The costs table alone records
nearly $50K of spend — loss would eliminate the financial audit trail.

---

## 2. Failure Domains

| Failure mode | Probability | Impact |
|---|---|---|
| Laptop disk failure / SSD corruption | Low-medium | Total loss |
| Accidental wipe (`rm -rf ~/.claude/logs/`) | Medium (agent risk) | Total loss |
| Malicious or erroneous agent deletion | Low | Total loss |
| DuckDB file corruption (incomplete write, crash during CHECKPOINT) | Low | Partial to total loss |
| Ransomware / OS-level encryption | Very low | Total loss |

The `destructive-fs-guard` hook blocks `rm -rf .claude/` with a confirmation code —
but an agent using `DESTRUCTIVE_CONFIRM=XXXX rm -rf ...` would bypass the advisory
layer. The primary protection must be an off-disk backup.

---

## 3. Backup Frequency Options

| Cadence | Pro | Con |
|---|---|---|
| **Hourly** | Max 1h data loss | 24× I/O per day; EXPORT takes ~2s each run |
| **Daily at 03:00** | After ETL at 02:00; low contention | Up to 24h data loss |
| **On-change via fswatch** | Near-zero data loss | Requires fswatch daemon; complex |
| **Weekly** | Minimal overhead | Up to 7 days data loss — unacceptable |

**Recommendation:** Daily at 03:00. The roborev ETL runs at 02:00; a 03:00 backup
catches the fresh data within one hour. The 24h RPO is acceptable given:
- sessions table updates are granular but the session itself is the atomic unit
- costs table is a daily aggregate — no intraday granularity is lost
- roborev tables are populated by ETL, so one ETL cycle = one day of data

---

## 4. Backup Location Options

| Location | Failure domain | Availability | Notes |
|---|---|---|---|
| `~/Backups/` same disk | SAME — not a backup | Instant | Violates backup-architecture rule |
| iCloud Drive (`~/Library/Mobile Documents/com~apple~CloudDocs/`) | DIFFERENT — Apple servers | Syncs in minutes | Available on this laptop; encrypted in transit; 5 GB free tier |
| External USB drive | DIFFERENT if unplugged | When connected | Not reliably present |
| Backblaze B2 | DIFFERENT — cloud object store | After upload | Requires API key setup; overkill for current scale |
| GitHub LFS private repo | DIFFERENT — GitHub servers | After push | 1 GB LFS free; DuckDB EXPORT produces ~5 MB parquet per backup |
| Time Machine (local snapshots) | SAME volume snapshots | N/A | `/Volumes/com.apple.TimeMachine.localsnapshots` is local; not a different failure domain |

**Recommendation:** Dropbox. The Dropbox client is already installed on this Mac
(`~/Dropbox -> ~/Library/CloudStorage/Dropbox`), provides a genuinely different
failure domain (Dropbox servers + any paired devices), syncs automatically without
extra credentials, and retains deleted files for 30 days (longer with paid plans).
A 30-day retention of daily backups requires ~150 MB of Dropbox storage (12 tables ×
30 days × ~400 KB per EXPORT).

iCloud Drive was the original recommendation but is NOT active on this Mac — the
directory `~/Library/Mobile Documents/com~apple~CloudDocs/` exists with only a
`.DS_Store` and a Desktop symlink (no synced content). Writing there would NOT
sync anywhere, failing the `backup-architecture` rule.

Backup path: `~/Dropbox/Backups/unified_duckdb/YYYY-MM-DD/`

---

## 5. Backup Mechanism Options

| Mechanism | WAL-safe? | Portable? | Notes |
|---|---|---|---|
| **`cp ~/.claude/logs/unified.duckdb <dest>`** | NO | Single file | Copies open WAL state; file may be corrupt on restore |
| **`duckdb <db> "CHECKPOINT; COPY ..."` + cp** | Partial | Single file | CHECKPOINT flushes WAL but race window remains |
| **`duckdb <db> "EXPORT DATABASE '<dir>'"` (Parquet)** | YES | Directory of `.parquet` | Reads consistent snapshot via MVCC; produces directory |
| **`duckdb <src> "ATTACH '<dest>' AS bk; COPY FROM DATABASE..."` | YES | `.duckdb` file | DuckDB 0.10+ only; simpler restore; single file |

**Recommendation:** `EXPORT DATABASE` to a dated directory. This uses DuckDB's MVCC
to take a consistent snapshot while the database may be in use. The output is a
directory of Parquet files (one per table) plus a `schema.sql` file — human-readable,
inspectable with any Parquet reader, and restorable with `IMPORT DATABASE`.

```sql
EXPORT DATABASE '~/Dropbox/Backups/unified_duckdb/2026-05-23'
  (FORMAT PARQUET, COMPRESSION ZSTD);
```

Restore:
```sql
-- Create new db
duckdb ~/.claude/logs/unified.duckdb.restored
-- Inside duckdb:
IMPORT DATABASE '~/Dropbox/Backups/unified_duckdb/2026-05-23';
```

---

## 6. Retention Policy

| Tier | Retention | Storage estimate |
|---|---|---|
| Daily | 30 days | ~150 MB (5 MB/day × 30) |
| Weekly (kept from daily) | 3 months | Additional ~60 MB |
| Monthly | 1 year | Additional ~60 MB |

Implementation: script deletes daily exports older than 30 days; the last daily of
each month is promoted to monthly tier (kept for 12 months). Weekly tier is not
implemented initially — the script prunes daily > 30 days only, and monthly > 365 days.

---

## 7. Restore Test Cadence

Manual restore test should be performed quarterly:
1. Find the most recent backup directory
2. Run `duckdb /tmp/test_restore.duckdb`
3. `IMPORT DATABASE '<backup_dir>'`
4. Verify row counts match `RECOVERY.md` reference
5. Delete `/tmp/test_restore.duckdb`

---

## 8. Comparison Table and Recommendation

| Option | Failure domain | WAL-safe | Automated | Storage | Complexity |
|---|---|---|---|---|---|
| `cp` same disk | SAME | No | Yes | Minimal | Minimal |
| **Dropbox `EXPORT DATABASE` daily** | **DIFFERENT** | **Yes** | **Yes** (launchd) | **~150 MB/month** | **Low** |
| iCloud `EXPORT DATABASE` daily | DIFFERENT (but iCloud sync not active on this Mac) | Yes | Yes | ~150 MB/month | Low (but inactive — would silently fail) |
| B2 `EXPORT DATABASE` daily | DIFFERENT | Yes | Yes | ~150 MB/month | Medium (API keys) |
| External drive (Passport) | DIFFERENT (when connected) | Yes | Partial | Unlimited | Low (already TM-registered) |

**Selected option:** Dropbox + `EXPORT DATABASE` (Parquet) + daily at 03:00 +
30-day daily retention + 12-month monthly retention. Implemented in
`.claude/scripts/unified_duckdb_backup.sh` and scheduled via
`.claude/launchd/com.claude.unified-duckdb-backup.plist`.

---

## 9. Files Produced

| File | Purpose |
|---|---|
| `plans/228-unified-duckdb-backup.md` | This analysis document |
| `.claude/scripts/unified_duckdb_backup.sh` | Backup script (--dry-run default, --apply writes) |
| `.claude/launchd/com.claude.unified-duckdb-backup.plist` | launchd daily 03:00 trigger |
| `RECOVERY.md` | Restore procedure per backup-architecture rule |
