# QA-check-reliability improvement initiative: false-negative/false-positive metrics + trend dashboard

## Context

This follows directly from the auto-merge-policy discussion (PR [#1060](https://github.com/JohnGavin/llm/pull/1060), already landed, explicitly out of scope here). The rejected fix was "stop auto-merging." The accepted fix is: make the checks that decide pass/fail/indeterminate actually trustworthy, and make their trustworthiness *measurable over time*, not just individually patched when an incident surfaces one.

The user's worked example sets three non-negotiable acceptance criteria for every check this plan touches:

1. **Exclude the check's own generated/rendered output** from what it inspects (no self-referential false-clean) — the `check_no_blank_plots()` / #786 lesson and the freshness-probe-reading-its-own-write lesson (#913) are the two in-repo instances of this exact defect.
2. **Label scope explicitly** — "clean within X," never unqualified "clean" — the `--no-denylist` public-runner disclosure in `private-data-scan.yml` and `check_dark_contrast.sh`'s documented blind-spot list are the two positive precedents to generalize.
3. **Print `unknown`/indeterminate, never a reassuring default** — this is precisely what `checks-must-distinguish-unknown.md` already codifies, and what `bin/roborev_merge_gate.sh`'s 3-state exit convention (0 pass / 1 block / 2 usage / 3 indeterminate) already implements structurally (verified directly: `bin/roborev_merge_gate.sh:15,109-110,137,181-195`). The gap is not the rule — it's that most checks in this repo don't yet *emit telemetry* for the indeterminate state they're already capable of returning, so nobody can see the rate at which "I don't know" is happening, whether it's shrinking, or whether a check's confirmed-false-negative rate is going up even while its exit code looks healthy.

**Press-release-first check, per house rule:** before proposing anything new, does an existing mechanism already cover it?
- A 3-state verdict convention → **already exists** (`checks-must-distinguish-unknown.md` + `bin/roborev_merge_gate.sh`'s exit codes). Not re-invented; extended into a schema.
- A "did this check run, what happened" table → **already exists** (`housekeeping_runs`), and two of the six checks in scope (secret scanner, PII scanner) **already write to it** via `run_id` FK on `secret_scan_findings` / `private_data_scan_findings` (verified: `housekeeping_schema_init.sql:225-226,244,279,293`). Not re-invented; extended with new columns.
- A human-judged-this-a-false-positive record → **already exists but roborev-only and unaggregated** (`closures.closure_type = 'wontfix'` + `closure_reason`). Not re-invented for roborev; the pattern is generalized to non-roborev checks via a new small table, because `closures` FKs to `reviews(id)`/`review_jobs(id)` — SQLite roborev-specific tables that no other check's findings live in.
- A self-verifying-negative pattern (assert the detector can detect before trusting its silence) → **already exists** (`private_data_scan.sh`'s `assert_can_detect()`). Not re-invented; named as the template Phase F's self-audit reuses.
- Newest-first table display → **already exists**, in the dashboard via base-R `order(..., decreasing = TRUE)` (e.g. `sess_claude` L3412, `block_table` L3785-3789). Not re-invented; the new "recent check outcomes" table follows the same idiom, sorted by timestamp instead of value.

Nothing here requires a new rule, a new sorting convention, or a new self-check mechanism from scratch — this plan is substrate reuse plus one genuinely new thing: **a place to record verdict+scope+indeterminate-reason as data**, because that place does not exist yet (confirmed via full-repo grep for `false_positive|false_negative|fp_rate|fn_rate|check_reliability`: zero hits as a schema column, table name, or metric identifier anywhere — greenfield).

## Explicit non-goals / boundaries

- **`.claude/scripts/roborev_merge_gate.sh`** (the old dry-run predecessor) is explicitly out of scope. It is documented "keep as-is" by its own header, and its indeterminate-collapse bug is explicitly not to be fixed under this plan — `bin/roborev_merge_gate.sh` is the gating implementation and the one this plan instruments.
- **`destructive_api_guard.sh`** stays exactly as-is. Its comment — `# Intentionally narrow: false positives are worse than false negatives.` — is a deliberate, documented policy divergence for irreversible-API-call blocking. This plan tracks and reports FP/FN/TN rates; it does not impose a blanket "reduce false negatives" tuning pressure on every check indiscriminately. Any per-check threshold tuning that Phase B's disposition data eventually motivates must be evaluated per-check against that check's own stated bias, not applied as a global policy.
- `roborev_metrics_schema.sql` stays untouched. FROZEN per llmtelemetry#144/llm#226. No new tables added there, no existing columns touched.
- `historical` repo is not explored this session and is out of scope (same boundary the [#800/#892/#920/#921/#928 blind-spots plan](https://github.com/JohnGavin/llm/pull/1058) already drew for #800).
- Exit-code conventions are **not universal** across checks — the `check_grep_portability.sh --selftest` mirror-image regression (a fix that broke a checker legitimately exiting 1 on a real finding) is the standing caveat: every check instrumented in Phase C gets an individual read of its actual exit-code semantics, never a blanket heuristic ("nonzero = didn't run" is exactly the mistake to avoid repeating).

## Phase A — Schema: extend `housekeeping_runs`, do not fork a new table

**Decision: additive extension of `housekeeping_runs`, not a parallel schema.**

Rationale, checked against the actual constraint (not assumed):

- `housekeeping_runs` is **not** frozen. Verified directly (`housekeeping_schema_init.sql:39-45`): unlike `roborev_metrics_schema.sql`'s explicit "SCHEMAS FROZEN" banner, `housekeeping_runs.status` is declared `TEXT NOT NULL` with the valid-value list only in a trailing comment — **no `CHECK` constraint enforces the enum**. Adding `'indeterminate'` as a fourth status value is a precedented move (the `'deferred'` value was added the same way, llm#947/#970, no migration).
- Two of the six checks in scope for this initiative — the secret scanner and the PII scanner — **already write to `housekeeping_runs`** (`secret_scan_findings.run_id` and `private_data_scan_findings.run_id` both FK to `housekeeping_runs.id`). Forking a parallel `qa_check_runs` table would mean those two checks either dual-write or get left out, for no benefit.
- One existing consumer does exclusion-based (not allowlist-based) status matching and would silently absorb the new value: `launchd_health_report.R:329,330,376` computes failure rate as `status NOT IN ('ok', 'deferred')`. An `'indeterminate'` row would fall into "failure" today — directionally not wrong (indeterminate isn't "ok"), but it conflates "confirmed broken" with "could not tell," the exact ambiguity this initiative removes. **Action in this phase:** update both `NOT IN` clauses to `NOT IN ('ok', 'deferred', 'indeterminate')` plus a separate `indeterminate` count column in the weekly health email, so the new state doesn't silently get absorbed into "failures" without a caller ever deciding that's what should happen.

**New columns on `housekeeping_runs`** (additive, `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`, same idiom already used for prior additive columns like `is_ephemeral`):

```sql
ALTER TABLE housekeeping_runs ADD COLUMN IF NOT EXISTS scope_label TEXT;
  -- satisfies acceptance criterion 2: "clean within X, never unqualified clean."
  -- e.g. 'excludes fixture files matching kb_fixture_*' or
  -- 'PR-checked-out commit range only, --no-denylist' -- free text, not enum,
  -- because scope varies per check family and forcing an enum here would
  -- itself become a source of silent mis-scoping.

ALTER TABLE housekeeping_runs ADD COLUMN IF NOT EXISTS indeterminate_reason TEXT;
  -- populated only when status = 'indeterminate'; the human-readable "why
  -- could this not answer" -- gh unresolvable, timeout, empty summary JSON,
  -- fixture missing, etc. NULL for 'ok'/'failed'/'partial'/'deferred'.
```

Plus the `status` enum's fourth value, `'indeterminate'` — documented in the header comment block exactly as `'deferred'` was, with the same "readers MUST NOT bucket X alongside Y" warning, extended to say readers MUST NOT bucket `'indeterminate'` alongside `'failed'` either.

**File:** `.claude/scripts/housekeeping_schema_init.sql` (edit the existing `CREATE TABLE housekeeping_runs` doc comment + append the two `ALTER TABLE` statements to `housekeeping_schema_apply.sh`'s idempotent-migration section).

## Phase B — Disposition table: human-judged FP/FN confirmation, generalized beyond roborev

The retrospective "was this actually right" judgment is inherently human-in-the-loop or incident-linked — a check cannot self-report its own false-positive/false-negative rate at run time, only its verdict. Roborev already has exactly this pattern for its own findings (`closures.closure_type = 'wontfix'` + `closure_reason`), but it (a) FKs into roborev's own SQLite tables only, (b) is never aggregated into a rate anywhere, and (c) only covers "a flagged finding was wrong" (false positive), not "a check said clean when an incident later proved it wasn't" (false negative).

**New table**, DuckDB, additive alongside `housekeeping_runs` (not roborev SQLite — this needs to cover non-roborev checks too):

```sql
CREATE TABLE IF NOT EXISTS qa_check_dispositions (
  id                TEXT PRIMARY KEY,       -- deterministic md5, same idiom as secret_scan_findings
  run_id            TEXT,                   -- FK -> housekeeping_runs.id; NULL if the original run
                                             -- predates instrumentation (see Phase D backfill)
  check_name        TEXT NOT NULL,          -- 'roborev_merge_gate' | 'roborev_consistency_check' |
                                             -- 'secret_exposure_scan' | 'private_data_scan' |
                                             -- 'qa_no_blank_plots' | 'deploy_publish_coverage' | ...
  disposition       TEXT NOT NULL
                      CHECK(disposition IN ('confirmed_false_negative',
                                             'confirmed_false_positive',
                                             'confirmed_true_positive',
                                             'confirmed_true_negative')),
  evidence_ref      TEXT NOT NULL,          -- issue number ('llm#1012'), CHANGELOG anchor, or
                                             -- roborev closure id -- always a checkable pointer,
                                             -- never a bare assertion
  reason            TEXT,                   -- free text, mirrors closures.closure_reason
  judged_at         TIMESTAMPTZ NOT NULL,
  judged_by         TEXT                    -- human identifier or 'backfill-script'
);
CREATE INDEX IF NOT EXISTS idx_qa_check_dispositions_check_name
  ON qa_check_dispositions(check_name, judged_at);
```

Roborev's existing `closures` table is **not migrated or duplicated** — it stays the system of record for roborev finding-level wontfix/approved/stale closures (its FK relationships to `reviews`/`review_jobs` are load-bearing and SQLite-side). Instead, a lightweight bridge job (extends `roborev_bridge_to_unified.sh`, which already moves roborev SQLite rows into `unified.duckdb`) mirrors `closures WHERE closure_type='wontfix'` into `qa_check_dispositions` as `confirmed_false_positive` rows with `check_name='roborev'`, `evidence_ref = closure_reason`. This is the one place roborev feeds the general mechanism rather than being reimplemented by it.

**Computable rate**, per check per time window (duckplyr, not raw SQL, per house rule):

```r
qa_check_dispositions |>
  filter(check_name == .x, judged_at >= window_start) |>
  count(disposition)
  # joined against housekeeping_runs count(status) for the same window
  # to get confirmed-FN / total-runs and confirmed-FP / total-flagged
```

This is inherently a lagging, incomplete-coverage metric — most runs will never get a disposition. **This itself is an instance of acceptance criterion 2**: the dashboard (Phase E) must show disposition counts and the confirmed subset, labeled explicitly as "confirmed false-negative rate (of dispositioned runs), not full population" — never implying completeness it doesn't have.

## Phase C — Prioritized instrumentation order

Ordered cheapest-and-highest-signal first, each closing a specific defect. C1-C6 have no dependencies on each other beyond Phase A and can land as independent PRs in this priority order.

**C1. `bin/roborev_merge_gate.sh` — cheapest, do first.**
Already fully 3-state (exit 0/1/2/3, `--json` verdict field already distinguishes `pass`/`block`/`indeterminate`, `failed_open: bool` already present — verified). Zero logic change needed. Add one `INSERT INTO housekeeping_runs` call at the existing single exit point — `task='roborev_merge_gate'`, `status` mapped from verdict (`pass`→`'ok'`, `block`→`'failed'`, `indeterminate`→`'indeterminate'`), `scope_label='PR head commit range, gh-resolved'`, `indeterminate_reason` populated straight from the existing `reason` field the JSON emitter already computes. This is the reference instrumentation — every subsequent check's telemetry write follows this exact shape.

**C2. `.claude/scripts/roborev_consistency_check.sh` — needs a logic fix AND telemetry.**
Two-part fix, in order:
1. **Logic fix first:** the header's own words are the bug — "0 for all invariants pass, check skipped due to missing tooling, OR no reviews in window." Five skip-paths (lines 83-113: `roborev` not installed, `jq` not installed, fixture not found, empty `summary --json`, invalid JSON) all currently `exit 0`, indistinguishable from a genuine pass by exit code alone. Change all five skip-paths to `exit 3` (matching `bin/roborev_merge_gate.sh`'s indeterminate convention), leaving `exit 0` meaning only "ran, invariants held," and adding the skip-reason string as the `indeterminate_reason` telemetry field. `session_init.sh`/`session-end.md` callers updated to treat exit 3 distinctly (log it, don't silently treat as pass).
2. **Telemetry:** same `INSERT INTO housekeeping_runs` shape as C1, `task='roborev_consistency_check'`, `scope_label='<window>, reclassified via classify_failure() vocabulary'` (the script's own header already documents this scope caveat around under-counted quota/crash — surface it verbatim).

**C3. Secret/PII scanners — verify and extend, do not rebuild.**
`secret_exposure_scan.sh` and `private_data_scan.sh` already write findings rows joined to `housekeeping_runs` via `run_id`. Gap to verify (not assume): does a **clean** run (zero findings) still write a `housekeeping_runs` row with `status='ok'`? If the current code only writes a row when findings exist, a clean run is currently invisible to any pass-rate computation — a silent-false-negative-shaped gap in the telemetry layer itself. Add `scope_label` at write time: `private_data_scan.sh`'s CI invocation `--no-denylist` on the public runner is already a documented narrower guarantee (per its own workflow comment) — this must appear in `scope_label`, not just in a comment, so acceptance criterion 2 holds in the data, not just in prose.

**C4. QA render gates (`plan_qa_gates.R`) — extend the existing 7-gate wiring, not a new mechanism.**
`check_no_nulls()` and `check_no_blank_plots()` already run as `targets` targets with `cue=tar_cue(mode="always")`. Add a telemetry-writing wrapper around the existing gate-calling convention (one shared helper, `emit_qa_gate_result()`, called by each gate function at its return point) rather than editing each gate's internal logic — `scope_label` carries the dual-signal calibration note ("file-size + near-white-pixel-fraction, calibrated against 4 known-good figures") verbatim from the gate's existing design rationale, and states explicitly "inspects rendered output, not source R code" (acceptance criterion 1).

**C5. Deploy-status gap — separate investigation track, not a single-script fix.**
The three deploy-status memory files (`feedback_prerendered-docs-deploy-verification.md`, `deploy-trigger-excludes-vignette-data.md`, `deploy-gap-stale-main-checkout.md`) describe three distinct root causes, not one script with a bug. This plan does not attempt to fix the underlying trigger-coverage gaps (a separate, larger workstream) — it scopes to **making the gap observable**: a new `housekeeping_runs` task `deploy_publish_coverage` that, after each `quarto-publish.yaml` run, records whether the triggering push touched files outside the `on.push.paths` filter, with `status='indeterminate'` and a reason like `"push touched inst/extdata/vignettes/vig_*.rds, no publish run observed"` when a mismatch is detected. A detector for the symptom, not a fix for any of the three root causes.

**C6. CI workflows — telemetry hook only.**
Each of the 6 workflows (`cross-repo-symlink-check.yml`, `private-data-scan.yml`, `quarto-publish.yaml`, `skill-security-scan.yml`, `vignette-validation.yml`, `wiki-sync-check.yaml`) already exits 0/nonzero. Add a final `if: always()` step writing a `housekeeping_runs` row via a shared `bin/emit_ci_check_result.sh` (new, thin wrapper around the same INSERT the local scripts use). Lowest priority — CI already blocks on these; the gap is trend visibility, not correctness.

## Phase D — Backfill: seed historical dispositions so the dashboard isn't empty on day one

Since this is greenfield, a scripted (re-runnable, not one-shot) backfill mines:
- ~35 CHANGELOG.md entries (2026-03 through 2026-08-27) matching `false positive|false negative|silently|phantom|indeterminate|gate said`
- the 16-row incident ledger at `.claude/incidents/2026-08-24-lessons-pending-config.md`
- the 6 issues cited by `checks-must-distinguish-unknown.md` (#1012, #746, #913, #1013, #1017, #1019)

into `qa_check_dispositions` rows with `disposition='confirmed_false_negative'`, `evidence_ref` set to the issue number or CHANGELOG anchor, `judged_by='backfill-script'`, and `run_id = NULL` (explicitly — the original run's `housekeeping_runs.id` does not exist for pre-instrumentation events, and inventing one would violate acceptance criterion 3 by fabricating precision that was never captured). `judged_at` is set to the incident's documented date, not today's date, so the trend chart's x-axis reflects when the defect actually happened.

**This backfill is explicitly best-effort/approximate for historical rows** — stated as a caveat both in the backfill script's own header comment and in the dashboard's chart caption. A free-text note in `reason` distinguishes "issue number cited directly" from "matched by CHANGELOG grep, not independently verified."

**New file:** `.claude/scripts/qa_dispositions_backfill.R` — idempotent on `evidence_ref` (`INSERT OR IGNORE`, matching `secret_scan_findings`'s deterministic-PK approach), so re-running after new incidents are added only inserts new rows.

## Phase E — llmtelemetry dashboard section

**Placement decision: new sub-tab under Reviews, named "Reliability," alongside Pulse/Quality/Operations/Cost/Detail.**
Not a new top-level tab (yet) — scope at launch is still roborev-adjacent-plus-a-handful-of-scripts. Recommend promoting to a top-level tab in a follow-up if/when non-roborev checks (C3-C6) dominate the row count — a deferred decision, not a foreclosed one.

**Two components, per the required output shape:**

1. **Cleveland dot chart, per-check confirmed-FN-rate over time** (ascending x-axis — the "reverse chronological" request applies to the table below, not this chart's time axis; every trend chart in this dashboard stays ascending/left-to-right, and house rule `visualization.md` bans pie/bar charts). One dot per (check_name, week) bucket, colored/ranked by check, y-axis = confirmed_false_negative_count / total_runs_in_bucket, following the pattern of `Quality > Agent Pass Rate` (`output$rv_agent_perf_chart`, L5349 — Cleveland dot, sorted by value), **not** the pre-existing `rv_noise_rate_chart` bar chart (a documented deviation from house rule already in the codebase — not to be copied).

2. **DT table, "recent check outcomes," newest-first**, using the `d[order(d$fired_at, decreasing = TRUE), ]` idiom already used at `sess_claude` (L3412) and `block_table` (L3785-3789). Columns: `check_name`, `verdict` (rendered as `"clean (scope: <scope_label>)"` / `"blocked"` / `"unknown — <indeterminate_reason>"` — never a bare "clean," satisfying acceptance criteria 2 and 3 directly in the UI, not just in the underlying data), `fired_at`, `disposition` (blank if undispositioned, else the confirmed label). Follows `dashboard-table-styling.md` (width auto, left-aligned, right-justified cells) and `dashboard-filter-placement.md` (a `card_header()` toolbar filter by `check_name`, not a page-level `selectInput`).

**ETL wiring** — two new numbered sections in `export_dashboard_data.R`, following the existing per-metric pattern (query `unified.duckdb` → `clean_projects()` → `group_by |> summarise |> arrange(date)` → `write_json()` to both `inst/extdata/` and `vignettes/data/` → wrapped in `tryCatch` with an empty-JSON fallback):

- Section "8m. Export qa_check_reliability_trend.json" — chart data, ascending by week.
- Section "8n. Export qa_check_recent_outcomes.json" — table data, sorted descending server-side (matching `sess_claude`'s idiom, for consistency with the majority of newest-first precedents found).

Both new JSON files must be added to the qmd's YAML `resources:` manifest (currently lines 8-66) — otherwise they silently don't ship in the Shinylive WASM bundle, a deploy-time false-negative of exactly the shape this initiative exists to catch — and loaded via `load_json()` (L371-380) alongside the existing calls.

## Phase F — Self-audit / recursion clause

Given the meta-finding that checks-of-checks have themselves shipped this exact defect (`check_indeterminate_handling.sh` missed llm#1012's own pattern on first ship; its own selftest fixtures were deleted before creation, making "0 findings" pass against files that didn't exist), the new instrumentation gets the same discipline applied to itself:

1. **Self-verifying negative for the telemetry writer**, generalizing `private_data_scan.sh`'s `assert_can_detect()`: before any check's telemetry wrapper (C1-C6) is trusted in CI, a test feeds a synthetic known-indeterminate run through the wrapper and asserts the resulting `housekeeping_runs` row lands as `status='indeterminate'`, never silently as `'ok'`. Same shape as `assert_can_detect()`, applied one layer up (to the telemetry write, not the content detector).
2. **Periodic re-audit of `check_indeterminate_handling.sh`'s baseline suppression list** (`.indeterminate-baseline`, `INDETERMINATE_ALLOWLIST`): a new `housekeeping_runs` task `indeterminate_baseline_audit`, scheduled monthly, that diffs the current baseline against a fresh `--all` scan and reports (as `status='partial'`, `rows_written` = new-instances-count) when a baselined file has grown new instances of the same defect class since the baseline was last written.
3. **The dashboard's own resources-manifest omission risk** gets one line in the Phase E PR's verification checklist: after deploy, load the live Shinylive page and confirm the new panel renders non-empty data — the render succeeding is not evidence the data shipped, precisely the user's original "decoration that looks like evidence" framing.

## Sequencing

```
A (schema: housekeeping_runs +2 cols, +indeterminate status)
  └── B (qa_check_dispositions table, roborev closures bridge)
        └── D (backfill, needs B's table to exist)
A ── C1 (merge gate telemetry) ── cheapest, no dependency beyond A
A ── C2 (consistency check: logic fix + telemetry)
A ── C3 (secret/PII scanners: verify + extend)
A ── C4 (QA render gates: shared wrapper)
A ── C5 (deploy-status gap detector)
A ── C6 (CI workflow telemetry hook)
B, C1-C6 ── E (dashboard: needs real rows from at least C1-C3 to not launch empty, needs D for historical depth)
A, B, C(all) ── F (self-audit: needs the mechanisms it's auditing to exist first)
```

## Per-phase landing summary

| Phase | Scope | PR scope | Depends on |
|---|---|---|---|
| A | Schema: `housekeeping_runs` +`scope_label`/+`indeterminate_reason`/+`'indeterminate'` status; fix `launchd_health_report.R`'s `NOT IN` exclusion | 1 llm PR | none |
| B | New `qa_check_dispositions` table + roborev `closures`→disposition bridge in `roborev_bridge_to_unified.sh` | 1 llm PR | A |
| C1 | `bin/roborev_merge_gate.sh` telemetry write | 1 llm PR | A |
| C2 | `roborev_consistency_check.sh` skip≠pass fix + telemetry | 1 llm PR | A |
| C3 | Secret/PII scanner clean-run + scope_label verification | 1 llm PR | A |
| C4 | `plan_qa_gates.R` shared `emit_qa_gate_result()` wrapper | 1 llm PR | A |
| C5 | `deploy_publish_coverage` detector (observability only, not a trigger-filter fix) | 1 llm PR | A |
| C6 | `bin/emit_ci_check_result.sh` + wiring into 6 workflows | 1 llm PR | A |
| D | Backfill script + one seeded run | 1 llm PR | B |
| E | Dashboard "Reliability" sub-tab, 2 new ETL sections, resources manifest + `load_json` wiring | 1 llmtelemetry PR | B, C1-C3 minimum (D for historical depth) |
| F | Self-verifying-negative tests per instrumented check + monthly baseline-drift audit cron | 1 llm PR (splittable per-check) | A, B, C(all) |

Cross-repo PR count: 1 llmtelemetry PR (Phase E); everything else is llm-only, matching the blind-spots plan's own cross-repo discipline (never bundle an llm change with an llmtelemetry change in one PR).

## Verification per phase

- **A**: new `tests/testthat/test-housekeeping-runs-indeterminate.R` — scratch DuckDB fixture, insert a row with `status='indeterminate'`, assert `launchd_health_report.R`'s updated query buckets it separately from `'failed'`. Manual: re-run against a copy of the real DB, confirm pre-existing status row counts unchanged (additive-only, no regression).
- **B**: new `tests/testthat/test-qa-check-dispositions.R` — scratch DB, insert a `closures` wontfix row (SQLite fixture), run the bridge, assert a matching `confirmed_false_positive` row lands in DuckDB with the right `evidence_ref`.
- **C1**: extend `bin/roborev_merge_gate.sh`'s existing scripted-scenario test coverage to assert a `housekeeping_runs` row is written for each of pass/block/indeterminate; verify the indeterminate path (simulate `gh` unresolvable) still exits 3 (unchanged) AND now also writes `status='indeterminate'`.
- **C2**: extend the script's `--fixture` mode with a fixture that forces each of the 5 skip-paths; assert exit code 3 (not 0) and a telemetry row with populated `indeterminate_reason`. Regression-check `session_init.sh` banner and `/bye` still function with the new exit code.
- **C3**: manual dry run of both scanners against a known-clean tree, confirm a `housekeeping_runs` row with `status='ok'` now appears (verify this is the specific gap the phase closes).
- **C4**: extend existing gate tests to assert `emit_qa_gate_result()` fires with the correct `scope_label` for `check_no_blank_plots()`'s dual-signal rationale.
- **C5**: new `tests/testthat/test-deploy-publish-coverage.R` — synthetic push touching only `.rds` vignette data, assert `status='indeterminate'` fires with the documented reason string.
- **C6**: dry-run one workflow (`private-data-scan.yml`) via `act` or a manual `workflow_dispatch`, confirm the `if: always()` step writes a row regardless of the scan step's own exit code.
- **D**: idempotency check — run the backfill script twice, assert row count unchanged on the second run.
- **E**: local `shiny::runApp()` smoke check of the new "Reliability" sub-tab + the Phase F item 3 post-deploy manual check that the live Shinylive page renders non-empty data, not just that the export script exits 0.
- **F**: each self-verifying-negative test is itself run in CI and asserted to fail loudly if commented out (one level of recursion, deliberately stopping there).

## Critical Files for Implementation

- `.claude/scripts/housekeeping_schema_init.sql` — Phase A schema extension; the reference for `secret_scan_findings`/`private_data_scan_findings`'s existing `run_id` FK pattern Phase C3 builds on
- `bin/roborev_merge_gate.sh` — Phase C1's instrumentation target and the 3-state exit-code reference pattern every other check's telemetry write follows
- `.claude/scripts/roborev_consistency_check.sh` — Phase C2's skip-paths (lines 83-113, all currently `exit 0`) needing the 3-state fix
- `.claude/scripts/roborev_schema_migration_v2.sql` — `closures` table (lines 50-74) Phase B bridges from, without modifying
- `~/docs_gh/llmtelemetry/inst/scripts/export_dashboard_data.R` — Phase E's new ETL sections, following the existing numbered-section/`write_json`/`tryCatch`-fallback pattern
- `~/docs_gh/llmtelemetry/vignettes/dashboard_shinylive.qmd` — Phase E's new "Reliability" sub-tab, resources manifest (lines 8-66), `load_json()` helper (lines 371-380), and the `order(..., decreasing = TRUE)` newest-first idiom (e.g. line 3412) to reuse for the outcomes table
