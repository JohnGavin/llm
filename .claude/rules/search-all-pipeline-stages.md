---
name: search-all-pipeline-stages
description: When checking data availability in multi-stage pipelines, search ALL stages (source → intermediate → final) before claiming data is absent
type: rule
---

# Rule: Search All Pipeline Stages Before Claiming Data Absence

## When This Applies

Any time you need to answer "do we have data for X?" or "is X available?" in a project
with a multi-stage data pipeline (files → extraction → database, or similar).

## CRITICAL: Absence at One Stage Does Not Mean Absence at All Stages

A multi-stage pipeline has source, intermediate, and final stages. Data may exist at
an earlier stage but not yet be processed into later stages.

```
Source files (PDF, API, raw/)
    ↓ extraction / transformation
Intermediate files (CSV, Parquet, JSON)
    ↓ loading / aggregation
Final store (database, warehouse, cache)
```

**Searching only the final store and concluding "data doesn't exist" is wrong.**
The data may be sitting unprocessed at the source stage.

## Required Search Order

When asked "do we have X?", search in this order:

1. **Final store** (database, cache) — fastest, most likely to have it
2. **Intermediate files** (CSV, Parquet) — may exist but not be loaded yet
3. **Source files** (PDF, raw downloads) — may exist but not be extracted yet
4. **External references** (letters, documents, logs) — may mention it exists elsewhere

If any stage returns empty, explicitly state which stages you checked:
"No X found in the database or CSV files. Checking source PDFs..."

## Pipeline Gap Detection

For file-based pipelines, check for unprocessed source folders:

```bash
# Generic pattern: source folders with no matching output folder
for d in source/*/; do
  [ ! -d "output/$(basename $d)" ] && echo "UNPROCESSED: $d"
done
```

Project-specific examples:
- mycare: `pdf/YYYY-MM-DD/` → `csv/YYYY-MM-DD/` → DuckDB
- ETL projects: `raw/` → `staging/` → `warehouse/`
- ML projects: `data/raw/` → `data/processed/` → model inputs

## CRITICAL: Use the Grep Tool, Not Bash grep

**Always use the dedicated `Grep` tool for content search. NEVER use `Bash("grep ...")`.**

The Grep tool handles large directories correctly. Bash `grep *.txt` with 100+ files
can silently fail due to shell glob expansion limits (ARG_MAX). When this happens:
- Bash grep returns 0 matches with no error message
- You conclude the data doesn't exist
- The data was there all along

This exact failure occurred in the mycare project: `grep -rli "remission" *.txt` on
117 files returned nothing. The Grep tool on the same directory found matches in
multiple files. The word "remission" was present in line 144 of a letter.

| Wrong | Why it fails | Right |
|-------|-------------|-------|
| `Bash("grep -rli 'term' dir/*.txt")` | Glob expands to 117 args, may hit limits | `Grep(pattern="term", path="dir/")` |
| `Bash("grep -c 'term' *.txt")` | Same glob problem | `Grep(pattern="term", path=".", output_mode="count")` |
| Multiple bash greps in sequence | Each can silently fail | Single Grep tool call with right path |

## What NOT To Do

| Wrong | Right |
|-------|-------|
| "No IgG results after March" (searched only database) | "No IgG in database. Checking CSVs... none. Checking PDFs... found in pdf/2026-04-20/" |
| "Data doesn't exist" (searched one folder) | "Data not found in csv/ or database. pdf/ has unprocessed files — checking those." |
| Grep only intermediate files | Grep source, intermediate, AND final |
| Bash grep on large directories | Grep tool (handles any directory size) |

## Origin

Incident: 2026-04-21 in mycare project. Agent searched csv/ and DuckDB for IgG data,
concluded none existed after March 2026. Missed `pdf/2026-04-20/Result Trends -
IMMUNOGLOBULINS G, A AND M - 20 Apr 2026.PDF` — 17 PDFs downloaded but not yet
converted to CSV. The user had to point out the file by name.

## Related

- `etl-data-quality` — data quality rules for medical ETL
- `verification-before-completion` — verify claims before stating them
