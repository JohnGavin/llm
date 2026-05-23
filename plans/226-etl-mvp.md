# Plan: #226 — roborev Metrics ETL MVP

**Issue:** [JohnGavin/llm#226](https://github.com/JohnGavin/llm/issues/226)
**Author:** Claude Sonnet 4.6 (fixer agent)
**Date:** 2026-05-23
**Status:** DRAFT — needs reviewer sign-off before implementation begins

---

## 1. Schema Decision (Frozen)

All 5 table schemas defined in #226 are **frozen** — `llmtelemetry` has a
companion issue (llmtelemetry#144) that reads `unified.duckdb` and depends on
these column names and types. No schema changes without a coordinated bump across
both repos.

**MVP requirement:** all 5 tables MUST be created (`CREATE TABLE IF NOT EXISTS`)
at ETL install time, even if only 2 are populated in the first slice. Downstream
consumers in llmtelemetry can query them immediately; empty tables are better than
missing tables that throw errors.

---

## 2. MVP Populate Scope

Implement ETL population for **2 of the 5 tables** first. The other 3 are created
empty and deferred.

| Table | MVP slice | Rationale |
|---|---|---|
| `roborev_daily_metrics` | **Slice 1 — populate** | Simplest rollup: daily join of `review_jobs` + `reviews` + severity autoclose log + counter JSON. All sources exist now. |
| `roborev_review_lifecycle` | **Slice 1 — populate** | Per-review timeline; most immediately useful for the llmtelemetry dashboard. All columns derivable from `review_jobs` + `reviews`. |
| `roborev_agent_performance` | Slice 2 — defer | Requires `token_usage` JSON parsing (nullable, often malformed) and join to `costs` table. Non-trivial NULL handling. |
| `roborev_threshold_changes` | Slice 2 — defer | Source is the severity autoclose log + config.toml diffs; needs a diff algorithm to reconstruct change events. |
| `roborev_cadence_efficacy` | Slice 2 — defer | Requires `review_jobs.source` field (present but sparsely populated); needs audit of poll-merges log format first. |

Slices 2+ are tracked in follow-up issues (see §10).

---

## 3. File Layout

```
~/.claude/scripts/
  roborev_metrics_etl.sh        # bash entrypoint — PATH setup, arg parsing, calls R
  roborev_metrics_etl.R         # ETL logic — duckplyr preferred over raw SQL
  roborev_metrics_schema.sql    # CREATE TABLE IF NOT EXISTS for all 5 tables (separate file)

~/.claude/logs/
  roborev_metrics_etl.log       # append-only; one line per run
  unified.duckdb                # target database (already exists)

~/.claude/launchd/              # template lives here (committed to git)
  com.claude.roborev-metrics-etl.plist

~/Library/LaunchAgents/         # symlinked or copied from above at install time
  com.claude.roborev-metrics-etl.plist
```

**Shell entrypoint (`roborev_metrics_etl.sh`):**
Same pattern as `roborev_severity_autoclose.sh` — explicit `PATH` prefix for
launchd, `set -euo pipefail`, flag parsing (`--dry-run` default, `--apply`,
`--since YYYY-MM-DD`, `--repo <name>`), then delegates to R via
`Rscript ~/.claude/scripts/roborev_metrics_etl.R "$@"`.

**R ETL script (`roborev_metrics_etl.R`):**
Uses `duckplyr` (tidyverse syntax) for all DuckDB writes — raw SQL strings
reserved for the schema creation step only (per `data-transformation-stack`
skill). Reads SQLite via `DBI` + `RSQLite`. Wraps everything in a single
`DBI::dbWithTransaction()` block so partial failures roll back cleanly.

---

## 4. Schema Migration

Create a dedicated `roborev_metrics_schema.sql` file (not inline in the R
script). Reasons:

- Reviewability: schema is a single artefact that can be audited independently
  of ETL logic
- llmtelemetry can reference it for documentation
- `CREATE TABLE IF NOT EXISTS` makes it idempotent — safe to re-run on every
  ETL invocation

The R script runs this file once at startup via
`DBI::dbExecute(con, readr::read_file(schema_path))` before any data writes.

### Primary data source per table

| Table | Primary source | Join / parse required |
|---|---|---|
| `roborev_daily_metrics` | `review_jobs` (enqueued_at, status) + `reviews` (verdict_bool) | daily GROUP BY; severity autoclose log line-parse; counter JSON parse |
| `roborev_review_lifecycle` | `review_jobs` + `reviews` | one row per `review_jobs.id`; parse `output` text for `severity_max`; parse launchd/log for `close_reason` |
| `roborev_agent_performance` | `review_jobs` (agent, model, token_usage JSON) | daily GROUP BY agent+model; percentile aggregation; joins `costs` table |
| `roborev_threshold_changes` | `~/.roborev/config.toml` history + severity autoclose log | reconstruct change events from log `source=` field; first record has NULL old_threshold |
| `roborev_cadence_efficacy` | `review_jobs.source` + `~/.claude/logs/roborev_poll_merges.log` | count poll invocations; join source field to distinguish poll vs hook |

---

## 5. Cadence

Daily at **02:00** — confirmed by user in #226 design decisions (2026-05-21).
02:00 is a quiet hour with no contention from llmtelemetry read queries or the
roborev poller (which fires at commit time, not on schedule).

Launchd plist key: `StartCalendarInterval` → `Hour=2, Minute=0`.
`RunAtLoad=false` (same as existing plists).

---

## 6. Out of Scope

The following are explicitly excluded from this MVP and tracked separately:

- **3 unpopulated tables** (`roborev_agent_performance`, `roborev_threshold_changes`,
  `roborev_cadence_efficacy`) — tables are created empty; ETL population is Slice 2
- **Dashboard consumption** — `llmtelemetry#144`; that repo owns all visualisation
- **Backfill beyond 7 days** — the 7-day initial backfill from `reviews.db` is in scope;
  full historic backfill (potentially years of data) is a separate ticket (§9)
- **Alerting on ETL failure** — log + exit code only; cron-based alerting is future work
- **Windows / CI portability** — ETL targets macOS local; no CI requirement

---

## 7. Acceptance Criteria for MVP

Minimum bar — **not mergeable until all pass:**

- [ ] `roborev_metrics_etl.sh --dry-run` exits 0 on a system with all inputs present
- [ ] `roborev_metrics_etl.sh --dry-run` exits 0 on a system with ALL inputs absent
  (graceful degradation to zeros)
- [ ] Self-test (`ROBOREV_METRICS_ETL_SELFTEST=1 bash roborev_metrics_etl.sh`) covers:
  absent counter JSON, absent severity autoclose log, malformed JSON in counter file,
  missing `reviews.db`
- [ ] After `--apply`, `unified.duckdb` contains **all 5 tables** (even if 3 are empty)
- [ ] `roborev_daily_metrics` contains non-empty rows for today + 7-day backfill
- [ ] `roborev_review_lifecycle` contains non-empty rows for today + 7-day backfill
- [ ] Re-running `--apply` twice produces identical row counts for both populated tables
  (idempotency via `INSERT OR REPLACE` keyed on PK)
- [ ] Launchd plist passes `plutil -lint`
- [ ] `plutil -lint ~/Library/LaunchAgents/com.claude.roborev-metrics-etl.plist` — 0 errors
- [ ] `~/.claude/logs/roborev_metrics_etl.log` updated with ISO-8601 timestamp and
  row counts after each `--apply` run

---

## 8. Risks and Mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| **Schema drift** — roborev upstream renames columns in `reviews.db` | Low (schema is stable) | Fail loudly: wrap `DBI::dbListFields()` check at ETL startup; if expected columns absent, exit non-zero with diagnostic message rather than silently emitting NULLs |
| **DuckDB write contention** with concurrent llmtelemetry read | Low (02:00 is quiet) | llmtelemetry readers use `read_only=TRUE` DuckDB connection; ETL transaction is short (<5s); if contention occurs, ETL retries once after 30s sleep before failing |
| **NULL / malformed JSON in `token_usage`** (review_jobs column) | Medium (field sparsely populated) | Wrap JSON parse in `tryCatch()`; emit NULL for `total_tokens_in`/`total_tokens_out` rather than aborting; log parse failure count per run |
| **Severity autoclose log format changes** | Low (format is controlled by us) | Pin the regex pattern as a named constant in the R script; add a format-validation check in the self-test suite |

---

## 9. Backfill Strategy (Deferred)

The MVP includes a 7-day initial backfill from `reviews.db` (driven by the
`--since` flag). Full historic backfill is a separate follow-up because:

- Historic data volume is unknown (could be months of review history)
- Backfill needs rate-limiting to avoid locking `reviews.db` for extended periods
- Some historic log entries (severity autoclose, cadence) may be absent for
  dates before those features existed — backfill logic must handle sparse sources

**Approach for the follow-up ticket:**
1. Run `--since 2024-01-01` (or earliest `review_jobs.enqueued_at` date) with
   `--apply` in a one-off terminal session (not launchd)
2. Process in 30-day chunks to bound memory and lock duration
3. Log a `BACKFILL` prefix in `roborev_metrics_etl.log` to distinguish from
   routine runs
4. Verify row counts against `SELECT COUNT(*) FROM review_jobs WHERE date(enqueued_at) = ?`

---

## 10. Related Issues

| Issue | Relationship | Action |
|---|---|---|
| [llm#226](https://github.com/JohnGavin/llm/issues/226) | This issue — data layer | Implement ETL (this plan) |
| [llm#228](https://github.com/JohnGavin/llm/issues/228) | Backup strategy for unified.duckdb | Depends on this: backup script needs the new tables to exist before it can checkpoint them |
| [llm#229](https://github.com/JohnGavin/llm/issues/229) | Governance / data retention for unified.duckdb | Lives alongside this: retention policy for `roborev_*` rows aligns with overall DuckDB governance |
| [llmtelemetry#144](https://github.com/JohnGavin/llmtelemetry/issues/144) | Dashboard consumer | Unblocked when all 5 tables exist; can start with the 2 populated tables |
| [llm#217](https://github.com/JohnGavin/llm/issues/217) | Cadence reduction | `roborev_cadence_efficacy` (Slice 2) answers its retrospective questions |
| [llm#224](https://github.com/JohnGavin/llm/issues/224) | Severity autoclose | `roborev_threshold_changes` (Slice 2) is its audit trail |

---

## Implementation Order

1. Write `roborev_metrics_schema.sql` (all 5 `CREATE TABLE IF NOT EXISTS`)
2. Write `roborev_metrics_etl.R` — schema init + Slice 1 populate only
3. Write `roborev_metrics_etl.sh` — bash wrapper with flag parsing + PATH
4. Add self-test block (same pattern as `roborev_severity_autoclose.sh`)
5. Write launchd plist template to `.claude/launchd/`
6. Manual install instructions (symlink to `~/Library/LaunchAgents/` + `launchctl load`)
7. Run `--apply --since $(date -v-7d +%Y-%m-%d)` to seed 7-day backfill
8. Verify acceptance criteria checklist (§7)
9. Open follow-up issues for Slice 2 tables + full backfill
