---
gitignore: false
note: This file SHOULD be committed. It contains restore instructions, not secrets. Credentials stay in .Renviron.
---

# RECOVERY — [project-name]

Restore instructions for non-reproducible state in this project.
Update this file whenever backup infrastructure changes.
Test the restore steps at least once per quarter and record the drill date below.

## What Needs Backing Up

List every piece of state that cannot be regenerated from `git` + a deterministic
pipeline. If the answer is "nothing — this project is fully reproducible", add
that statement and stop; no backup infrastructure is needed.

| Asset | Description | Why irreproducible |
|---|---|---|
| `data/predictions/*.jsonl` | Inference logs — `llmtelemetry` | Generated at runtime; ~500 KB/day, cannot replay |
| `inst/extdata/irish_buoys.duckdb` | ERDDAP cache — `irishbuoys` | Provider rolling ~2yr window; old obs expire |
| `pdf/` | Lab results / letters — `mycare` | GP portal retains ~18 months; retrieval after that is manual |

## Where Backups Live

| Asset | Backup location | Failure domain | Retention |
|---|---|---|---|
| `data/predictions/` | `s3://my-bucket/llmtelemetry/predictions/` | Different cloud account | 90 days |
| `inst/extdata/*.duckdb` | `/Volumes/NAS/backups/irishbuoys/` | Local NAS, different drive | 30 days |
| `pdf/` | `/Volumes/NAS/backups/mycare/pdf/` | Local NAS, different drive | Indefinite |

**Failure domain check (mandatory):** confirm the backup location is not on
the same volume, same cloud account, or same machine as the primary. See the
`backup-architecture` rule for the decision table.

## RPO (Recovery Point Objective)

Maximum acceptable data loss on full disaster:

| Asset | RPO | Backup frequency |
|---|---|---|
| `data/predictions/` | 1 day | Daily cron, 02:00 local |
| `inst/extdata/*.duckdb` | 7 days | Weekly cron, Sunday 03:00 |
| `pdf/` | 7 days | Weekly cron, Sunday 03:00 |

## RTO (Recovery Time Objective)

Estimated time to complete a full restore:

| Asset | RTO | Bottleneck |
|---|---|---|
| `data/predictions/` | ~15 min | S3 download speed |
| `inst/extdata/*.duckdb` | ~5 min | NAS read speed |
| `pdf/` | ~10 min | NAS read speed + file count |

## Restore Steps

```bash
# 1. Confirm backup is intact and recent
aws s3 ls s3://my-bucket/llmtelemetry/predictions/ | tail -3   # llmtelemetry
ls -lht /Volumes/NAS/backups/irishbuoys/ | head -3             # irishbuoys / mycare

# 2. Restore
aws s3 sync s3://my-bucket/llmtelemetry/predictions/ data/predictions/
cp /Volumes/NAS/backups/irishbuoys/irish_buoys_YYYY-MM-DD.duckdb inst/extdata/irish_buoys.duckdb
rsync -av /Volumes/NAS/backups/mycare/pdf/ pdf/

# 3. Verify (see next section)
```

## Verification

Confirm the restore is consistent before marking recovery complete.
Compare against expected minimums recorded below (update after each drill).

| Asset | Check | Expected minimum | Last verified |
|---|---|---|---|
| `inst/extdata/irish_buoys.duckdb` | `SELECT COUNT(*) FROM observations` | ≥ 500 000 rows | YYYY-MM-DD |
| `data/predictions/` | `ls *.jsonl \| wc -l` | ≥ 90 files | YYYY-MM-DD |
| `pdf/` | `find pdf/ -name '*.pdf' \| wc -l` | ≥ 47 files | YYYY-MM-DD |

## Owner

| Role | Name / contact |
|---|---|
| Primary owner | john.b.gavin@gmail.com |
| Backup owner | — |

## Last Drill

| Date | Who | Outcome | Notes |
|---|---|---|---|
| YYYY-MM-DD | — | — | Initial entry — drill not yet performed |

**Drill procedure:** Delete the local primary. Run restore steps above.
Run verification. Confirm row counts / file counts match expected values.
Record date and outcome in the table above. Commit this file.

Cadence: quarterly (next due: YYYY-MM-DD).
