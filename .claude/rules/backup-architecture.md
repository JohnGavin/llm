---
name: backup-architecture
description: Backups must live in a different failure domain from the primary — same-volume snapshots are not backups; projects capturing irreplaceable data require a RECOVERY.md
type: rule
---

# Rule: Backup Architecture — Different Failure Domain

## Source

PocketOS / Cursor / Railway incident 2026-04-25
([thread](https://x.com/lifeof_jer/status/2048103471019434248)):
Railway's volume backups lived on the same volume as the primary data.
When the volume was deleted (by an agent via a single GraphQL mutation), the
backups were deleted with it. The most recent recoverable backup was three
months old. Architectural finding: **a backup stored in the same failure
domain as the primary is a snapshot, not a backup**.

## When This Applies

Any project that captures state that cannot be regenerated from `git` plus a
deterministic pipeline (`tar_make`, `nix-build`, `quarto render`). Examples:

- Time-series captured from live APIs (provider data changes or expires)
- Scraped pages or PDF imports (source may become unavailable)
- Manual data entry or patient records
- Prediction logs and audit/event records
- Database state with user edits

## CRITICAL: Same Failure Domain = Not a Backup

A "backup" that shares the blast radius of the primary is destroyed in the
same incident that destroys the primary. Useful backups require physical or
logical separation.

## State Classification Table

| State type | Reproducible? | Backup needed? | Example projects |
|---|---|---|---|
| Source code (in git) | Yes — from git | No — git IS the backup | All |
| Pipeline outputs (from sources via `tar_make` / `nix-build` / `quarto render`) | Yes — rebuild from source | No — rebuild | `llm`, `randomwalk`, `urban_planning`, `footbet` |
| API-captured time-series | No — provider data changes | YES — different domain | `irishbuoys` (ERDDAP cache), `llmtelemetry` (predictions JSONL) |
| Scraped / PDF imports | No — source may disappear | YES — different domain | `mycare` PDFs, any scrape project |
| Database state with edits | No | YES — different domain | Any DB with user-edits |

## Failure Domain Definitions

| Same domain (NOT a backup) | Different domain (real backup) |
|---|---|
| Same volume / disk | Different physical drive |
| Same cloud account | Different cloud account |
| Same hosting provider | Different provider |
| Same machine | Different machine |
| Same git remote (no local copy) | Local clone + remote, OR two remotes |
| Railway / Fly.io "volume backup" feature (same volume) | S3 / Backblaze B2 / local NAS |

## Per-Project RECOVERY.md

Any project where "Backup needed? = YES" MUST have a `RECOVERY.md` at the
repo root documenting:

- What non-reproducible state exists
- Where backups live (failure domain + path/URL + retention policy)
- RPO (recovery point objective) and RTO (recovery time objective)
- Numbered restore steps
- How to verify the restore is consistent (row counts, checksums)
- Owner and last drill date

Use the template at `~/.claude/templates/RECOVERY.md` (project local) or
`~/docs_gh/llm/.claude/templates/RECOVERY.md`.

`RECOVERY.md` is NOT gitignored — restore instructions should be visible to
anyone recovering the project. It must not contain secrets (paths and
retention policies only; credentials stay in `.Renviron`).

## Audit Candidates

The following projects in `~/docs_gh/` have potentially non-reproducible
state and need a `RECOVERY.md` written (per-project work, out of scope here):

- **`llmtelemetry`** — predictions JSONL; generated at inference time, cannot
  be regenerated from source
- **`irishbuoys`** — ERDDAP API cache; provider data has a rolling availability
  window, historical observations may become unavailable
- **`mycare`** — PDF imports (lab results, letters); originals held by
  healthcare provider but retrieval is manual and lossy

All other projects surveyed (`llm`, `randomwalk`, `urban_planning`, `footbet`,
`acd_area_climate_design`, `rix.setup`) are fully reproducible from git +
pipeline and do not require backup infrastructure.

## Forbidden Patterns

| Pattern | Why wrong |
|---|---|
| Relying on Railway / Vercel / Fly.io "volume backup" without verifying it lives outside the volume | Same-domain snapshot — destroyed with the primary |
| Calling a rolling snapshot a backup | Snapshot ≠ backup if same failure domain |
| No `RECOVERY.md` in a project with irreplaceable data | No documented restore path |
| Backup target in the same git remote as the primary | One delete wipes both |
| "Our cloud provider handles backups" without checking cross-account/region policy | Provider may store backup in the same region or account |

## Related

- `safe-deletion` — `rm` discipline; this rule adds cross-domain backup requirements
- `script-destructive-ops` — hook-level guard on destructive file-system ops
- `destructive-api-calls` — hook-level guard on API deletions (the incident vector)
- `permission-mode-discipline` — blast-radius reduction via workspace isolation
- `data-in-packages` — data versioning patterns (date-partitioned parquet, DuckDB snapshots)
