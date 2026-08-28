# Combined plan: #800, #892, #920, #921, #928 (monitoring-that-reports-success-while-broken)

## Context

Five open P0-blind-spots issues share a family resemblance: a gate, metric, or
dashboard reports "fine" while the underlying thing is silently broken. The
2026-08-28 auto-fix sprint closed the quick, self-contained items in this
cluster (#829, #904, #937, #894, #830); these five remain because each is
explicitly a **design proposal**, not a bug fix — several end their issue body
with a "Proposed scope" section rather than a patch. They were parked for a
dedicated planning session rather than rushed.

Two of the five (#920, #921) and one workstream inside a third (#892) share
real infrastructure — a governed "trusted" view and a content-verification gate
family — so this plan sequences them to build shared substrate once instead of
five bespoke solutions. #800 and #928 are related in *principle*
(zero-metric-evidence-or-defect) but not in *code*; they land independently.

Everything below was grounded against the actual codebase (three parallel
Explore passes + one Plan synthesis, all citing file:line) before being
written — no invented conventions where an existing one already fits.

## Phase A — Governed SSOT view (#920), lands first (foundation for Phase C)

**A1 — llmtelemetry, urgent stopgap, ships alone first.**
`inst/scripts/export_dashboard_data.R`'s cost-by-project weighting (~line
1528, section "9. Estimated cost by project") has **no exclusion at all** for
the reaper-synthetic `duration_min=120.0` rows — confirmed zero hits for
"reaper"/"120." in that file. `llm`'s dashboard already excludes them via a
hardcoded string match (`inst/shiny/dashboard/app.R:890,974`,
`summary NOT LIKE '%llm#803 reaper%'`). Copy that exact string-match into the
`u_sess_df` build right before the weighting calc — deliberately temporary,
replaced by A3. Own PR (cross-repo rule: never bundle with an `llm` change).

**A2 — llm, `sessions_trusted` view.**
New `.claude/scripts/sessions_trusted_schema.sql` (copy `staleness_schema.sql`'s
`CREATE OR REPLACE VIEW` header/idempotency convention — recompute-at-read,
never a cached status column, per `checks-must-distinguish-unknown`):

```sql
CREATE OR REPLACE VIEW sessions_trusted AS
SELECT s.*
FROM sessions s
WHERE NOT EXISTS (
  SELECT 1 FROM data_quality_incidents dqi
  WHERE dqi.asset = 'sessions'
    AND (dqi.column_name = 'duration_min' OR dqi.column_name IS NULL)
    AND s.started_at >= dqi.window_start
    AND (dqi.window_end IS NULL OR s.started_at < dqi.window_end)
);
```

Plus `sessions_trusted_schema_apply.sh` (copy `staleness_schema_apply.sh`
verbatim shape). Migrate `app.R:890,974` off the string match onto
`sessions_trusted`. Leave the `*`-suffix "estimated" display marker as-is
(cosmetic, not correctness-bearing).

**A3 — llmtelemetry, migrate to the view + investigate atomic publication.**
Depends on A2 landing and being verified. Add `read_unified_sessions_trusted()`
to `llmtelemetry/R/read_unified.R` (same shape as its 4 existing functions).
Point section 9's weighting calc at it; delete A1's stopgap string match.
Separately: check whether `write_json_atomic()` (already used throughout the
exporter) is atomic per-file but not across the ~15-file export set — if a
mid-deploy read can see a stale/fresh mix, add a completion-marker sentinel
file written last; if the deploy path already publishes atomically, document
that as "checked, not needed" rather than shipping unused machinery.

**A4 — cross-repo recurrence guard, both repos, after A2/A3.**
Same detection heuristic implemented twice (roborev's `classify_failure()`
precedent: duplicate deliberately, don't unify across repos) — `llm` gets a
new `qa_data_quality_incident_coverage` gate in `plan_qa_gates.R`;
`llmtelemetry` gets an equivalent step in `.github/workflows/pr-checks.yaml`.
Both warn (not abort) — it's a static heuristic scan, not a proof.

## Phase B — Content-verification gate family (#892), llm-only, after Phase A

Resolves the issue's three open design questions:

1. **Tolerance policy** — one per-target registry with a `.default` fallback
   (`QA_CONTENT_REGRESSION_TOLERANCES` constant in `plan_qa_gates.R`, same
   shape as `staleness_schema.sql`'s per-asset `metric_threshold_high`), rolled
   out in **warn mode** first (matching `qa_no_raw_sql`'s existing
   warn-not-abort precedent), flipped to abort per-target once warn-mode output
   shows the floors don't false-positive on legitimate data growth/shrinkage.
2. **Where it runs** — both exporter-side and pipeline-gate-side, mirroring the
   existing 2-surface pattern `check_no_nulls()` already uses (store value +
   committed snapshot, because a defect can hide in either).
   `data-raw/export_vignette_snapshots.R` computes the manifest and refuses to
   overwrite on a hard-invariant break (e.g. nonzero→zero rows); a new
   `qa_content_regression` pipeline gate re-verifies at build/CI time by
   diffing the manifest against git history — the one that actually blocks a
   merge.
3. **Manifest format** — plain text, modeled on this repo's own testthat
   `_snaps/*.md` convention (already the established "small
   human-reviewable file beside what it verifies, diffed in a PR" pattern —
   don't invent a new one). One `<target>.manifest.txt` per committed `.rds`:
   `nrow`, `ncol`, `n_na_total`, `n_na_by_column`, `distinct_levels_<col>`,
   `git_blob_sha`, `generated_at` — deterministic, sorted key order.

Gate sub-checks, cheapest-first: (1) absolute-path scan of the raw `.rds`
bytes for `/nix/store/`, `/Users/`, `/private/var/` — catches #883-class leaks
without deserializing, no dependency on the other checks; (2) row-count floor
vs. tolerance; (3) category/factor-level coverage (new manifest's levels must
be a superset within tolerance); (4) NA-share drift. Diff against history via
`git show <prev-commit>:<manifest_path>` (same R-to-git plumbing pattern
`plan_scrolly_config.R:153` already uses) — never re-deserializes two `.rds`
versions, only diffs two small text files.

Files: `R/tar_plans/plan_qa_gates.R` (new `check_content_regression()` +
`qa_content_regression` target, same wiring as the 7 existing gates:
`targets::tar_target(name, check_fn(), packages=c(...), cue=tar_cue(mode="always"))`),
`data-raw/export_vignette_snapshots.R` (manifest generation at write time).

## Phase C — Degenerate-distribution gate (#921), llm-only, after Phase A

**Land the gate first** (issue's own "can ship independently, highest value"
framing). New `check_degenerate_distribution()` / `qa_degenerate_distribution`
in `plan_qa_gates.R`, same wiring pattern as Phase B. ~10 lines of SQL per the
issue's own estimate: flag when, over a rolling window, a numeric column is a
single constant for >50% of rows, has zero variance, or is bimodal with an
empty interior. **Queries `sessions_trusted`, not `sessions`** — this is why
Phase A must land first; querying the untrusted table would mean the gate
can't distinguish a real degenerate distribution from the reaper's own
synthetic constant, the exact failure mode it exists to catch.

Extend `unified-observability-schema.md`'s Data Quality Incidents section (doc
change, not code): a column registered in `data_quality_incidents` should also
get a `qa_degenerate_distribution` check.

**Dashboard distribution panel** (p50/p95/p99 + CDF/histogram for
`duration_min` and cost/latency in `inst/shiny/dashboard/app.R`) is explicitly
lower priority per the issue — lands after the gate is verified working, same
phase or a follow-up PR.

## Phase D — Exposures table + column-consumer gate (#800), llm-only

Different mechanism from Phase B (declares consumers, doesn't check content) —
sequenced after B only because both touch `plan_qa_gates.R`, not because of a
real dependency. New `.claude/scripts/exposures_schema.sql`
(`CREATE TABLE IF NOT EXISTS`, one row per target-column → consumer edge, plus
an `internal=TRUE` escape hatch). New `check_exposures_coverage()` /
`qa_exposures_coverage` gate, same wiring pattern. One-line PR template
addition: "names the output this change is visible in, or states why none"
(`.github/PULL_REQUEST_TEMPLATE.md`).

**Explicitly out of scope for this plan:** the retro-sweep of #800's 4 named
`historical`-repo instances and `historical`'s own red `qa_summary` check —
`historical` is a third repo not explored this session; file a follow-up issue
there referencing #800 rather than designing it blind. Usage tracking is
deferred per the issue's own "lower priority" framing.

## Phase E — roborev ETL gaps 3–5 (#928), llm-only, independent track

Gaps 1–2 (capture `rj.error`, `classify_failure()` → `jobs_failed_*` columns)
are **already shipped** in this worktree (`roborev_metrics_etl.R:227-521`,
marked "llm#928, 2026-08-06"). Remaining, no dependency on Phases A–D:

- **Gap 3** — `roborev_daily_metrics` still carries 720 dead/ephemeral repo
  rows the source cleanup (#923) never reached. Add an `is_ephemeral` flag
  (idempotent `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`, same pattern as the
  existing `jobs_failed_*` additive columns) rather than a destructive repair;
  consumers filter on the flag.
- **Gap 4** — extend the existing fixture-path guard
  (`roborev_metrics_etl.R` ~line 279) to catch the second fixture family
  (`kb_fixture_*`, `tmp.*`), plus an explicit "no new fixture family since
  deploy" drift check.
- **Gap 5** — no metric exists for "commits with a failed review and no
  successful review" (#927's dropped-review count, currently 35). Generalize
  `roborev_requeue_dropped.sh`'s existing CTE query (lines 790-824, currently
  quota-only) to all terminal failure categories. Primary home:
  `roborev_repo_stats()` in `app.R:204-238` (issue's own "natural home" claim,
  confirmed independent of the ETL, reads SQLite directly — add one more
  `SELECT count(...)` to its existing multi-part query). The ETL's
  `jobs_failed_*` columns feed a secondary cross-check view, not the primary
  source (already confirmed unwired to any dashboard consumer today).
- **One-time data cleanup, not code:** remove the stray
  `llm923_guard_test_repo` fixture row; de-duplicate `repos.name` for
  `historical`/`tennis` (each appears twice at different paths). Run once
  against the live DB; note in the PR as data-only, no code diff to review.

## Cross-repo PR count

3 llmtelemetry PRs total (A1, A3, A4's llmtelemetry half); everything else is
llm-only. Never bundle an llm change with an llmtelemetry change in one PR,
per `auto-delegation`'s cross-repo rule.

## Sequencing

```
A1 (llmtelemetry stopgap) ── ships alone, first
A2 (llm: sessions_trusted) ── A3 (llmtelemetry: migrate + manifest) ── A4 (cross-repo guard, both repos)
A2 ── C (degenerate-distribution gate reads sessions_trusted)
B (content-regression gate) ── D (exposures gate; shares wiring only)
E (roborev) ── fully independent, can start anytime
```

## Per-issue landing summary

| Issue | Phase(s) | Deferred / out of scope |
|---|---|---|
| #800 | D | `historical`-repo retro-sweep + its `qa_summary` fix (follow-up issue there); usage tracking |
| #892 | B | none — all 3 design questions resolved above |
| #920 | A1–A4 | uniforming the rest of `export_dashboard_data.R`'s inline-connection style |
| #921 | C | none — dashboard panel (part 1) explicitly sequenced after the gate (part 2), same phase |
| #928 | E | none substantive — gaps 1–2 already shipped pre-plan |

## Verification (per phase, using existing conventions — no new test harness)

- **A2/A3**: new `tests/testthat/test-sessions-trusted-view.R` (scratch DuckDB
  fixture, same style as existing QA-gate tests) + `test-read_unified.R`-style
  fixture test for the new llmtelemetry helper. Manually re-point the
  dashboard/exporter at a copy of the real `unified.duckdb` and confirm totals
  match the pre-migration string-match exactly (the view must reproduce the
  same excluded row count, not just compile).
- **A4**: `devtools::test()` fixture that plants a fake unguarded aggregation
  and asserts the gate flags it; llmtelemetry side verified via a dry run of
  `pr-checks.yaml` against a deliberately-reverted diff.
- **B**: new `tests/testthat/test-qa-content-regression.R` (scratch git repo +
  targets store fixture, commit a manifest, mutate it, assert fire/no-fire).
- **C**: new `tests/testthat/test-qa-degenerate-distribution.R` with a
  synthetic 99.6%-constant fixture (mirroring the real 2028/2036 incident)
  that must fail, and a normal-variance fixture that must pass. Dashboard
  panel verified via local `shiny::runApp()` smoke check (no `testServer`
  convention exists for this dashboard's other panels either).
- **D**: new `tests/testthat/test-qa-exposures-coverage.R` (plant an
  undeclared column, assert failure; declare it or mark `internal=TRUE`,
  assert pass).
- **E**: extend `tests/testthat/test-roborev-failure-category.R` for gaps 3–4;
  new assertions wherever `roborev_repo_stats()` is currently tested (check
  `test-roborev-dashboard-link.R`) for gap 5's new count.

## Critical files

- `R/tar_plans/plan_qa_gates.R` — every new gate's home
- `.claude/scripts/staleness_schema.sql` — the view convention to copy
- `.claude/scripts/data_quality_incidents_seed.sql` — existing incident rows
- `inst/shiny/dashboard/app.R` — `llm` dashboard, lines 204-238 (`roborev_repo_stats`), 870-978 (reaper exclusion)
- `/Users/johngavin/docs_gh/llmtelemetry/inst/scripts/export_dashboard_data.R` — cost weighting, ~line 1528
- `/Users/johngavin/docs_gh/llmtelemetry/R/read_unified.R` — DB-read helper convention
- `.claude/scripts/roborev_metrics_etl.R` — gaps 1–2 already shipped here; gaps 3–4 land here too
- `.claude/scripts/roborev_requeue_dropped.sh` — gap 5's query to generalize
