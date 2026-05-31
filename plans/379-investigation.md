# Issue #379 — Investigation: roborev DB review → fix-commit link

**Date:** 2026-05-31
**Investigator:** fixer agent (sonnet)

---

## Source database schema (reviews.db)

Tables relevant to this issue:

| Table | Key columns | Notes |
|---|---|---|
| `repos` | `id`, `name`, `root_path` | 40+ repos; `root_path` is the local git checkout path |
| `review_jobs` | `id`, `repo_id`, `commit_id`, `git_ref`, `branch`, `status`, `enqueued_at` | `commit_id` FK → `commits.id` |
| `reviews` | `id`, `job_id`, `closed`, `verdict_bool`, `output`, `updated_at` | one per job; closed=1 with updated_at = close timestamp |
| `commits` | `id`, `repo_id`, `sha`, `author`, `subject`, `timestamp` | 2,581 rows; the commit SHA that triggered the review job |
| `closures` | `id`, `finding_id`, `closure_commit_sha`, `closure_type`, `closure_reason`, `created_at` | **0 rows currently** — this table exists but is unpopulated |
| `responses` | `id`, `job_id`, `response` | used for `auto-closed:` markers |

### Key finding: closures table exists but is empty

The `closures` table already has `closure_commit_sha` — but it has 0 rows.
Nothing populates it in the current codebase. This is not the right source
for fix-commit links; we must derive them via heuristics.

### Reviews scale

- Total reviews: 5,035
- Closed reviews: 3,945 (78.3%)
- The `reviews.updated_at` field holds the closure timestamp (when closed=1)

### Repos have `root_path`

`repos.root_path` gives the local filesystem path for `git log` queries.
This is the key enabler for heuristic 1 (explicit reference) and 3 (time-proximity).

---

## Target DuckDB schema (unified.duckdb)

`roborev_review_lifecycle` has 16 columns, PK = `review_id`. Currently:
- `commit_sha` is always NULL (comment: "Slice 2: join via commits table")
- `autoclose_threshold_at_close` is always NULL (comment: "Slice 2")
- `close_reason` is populated (5-value vocabulary)

The new columns `fix_commit_sha`, `fix_commit_at`, `fix_method` are NOT
currently in this table. Decision needed: extend or separate table.

---

## Design decision: EXTEND roborev_review_lifecycle vs new table

**Decision: extend `roborev_review_lifecycle` with 3 new columns.**

Rationale:
1. `roborev_review_lifecycle` is the canonical per-review record; fix-commit
   link is 1:1 with review, not 1:N → no separate table needed
2. llmtelemetry #146 Q4/Q9/Q14 reference `roborev_review_lifecycle` directly;
   adding columns there avoids a JOIN in every downstream query
3. Precedent: `commit_sha` and `autoclose_threshold_at_close` are already
   deferred NULLs in the same table (Slice 2 placeholders)
4. `roborev_review_lifecycle` PK = `review_id`; INSERT OR REPLACE handles
   backfill cleanly when re-running ETL

The schema note says "SCHEMAS FROZEN — llmtelemetry#144 depends on these
column names". Adding NEW columns is additive and safe for DuckDB (the
downstream consumer uses SELECT by name, not position). We document this
in the schema file comment.

---

## Heuristic chain

### Heuristic 1: explicit commit reference

Scan `git log --grep 'roborev.*<id>'` within ±1 day of `closed_at` in the
repo's `root_path`. This is the strongest signal and almost zero false-
positive rate.

**Limitation:** requires the repo path to exist on this machine.
Check `file.exists(root_path)` before running; skip gracefully if absent.

### Heuristic 2: PR close

`gh pr list --search` for PRs closed near `closed_at` that mention the
review ID. Expensive (network) and low yield given the local-only workflow.
**Included for completeness but not run in batch** — only when heuristic 1
misses and `fix_method` would otherwise be `unknown`. Rate-limited with
`tryCatch`.

### Heuristic 3: time-proximity

`git log --since <closed_at - 6h> --until <closed_at>` in the same repo.
Commits by the same `closer_actor` within 6 hours before closure are
candidates. Mark as `fix_method = "manual"` (low confidence).

**Limitation:** `closer_actor` is not reliably stored in reviews.db. We
use `reviews.updated_by_machine_id` or fall back to any commit by any
author in the window.

### Heuristic 4: autoclose

When `close_reason LIKE 'severity-%'` or `close_reason = 'clean-verdict'`:
the review was closed automatically, not by a human fix. Set
`fix_method = "autoclose_severity"`, `fix_commit_sha = NULL`.

### Heuristic 5: fallthrough

`fix_method = "unknown"`, NULLs elsewhere.

---

## Batch guard

Process only reviews where `fix_commit_sha IS NULL AND closed = 1`.
This prevents redundant git-log scanning on already-linked reviews.

---

## Test fixture approach

Mirror `test-roborev-etl-lifecycle.R` pattern:
- Source a line range from the ETL script containing the new functions
- Build a synthetic SQLite fixture with 3+ review cases
- Assert correct classification per case

`testthat::test_file()` parse-safe; actual R execution deferred to
`devtools::test()` in the llm nix shell.
