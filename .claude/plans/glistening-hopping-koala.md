# Plan: Prediction Calibration Tracking (llm#47)

## Context

Claude should attach probability estimates to tasks before starting, then record outcomes after. Over time this builds a calibration dataset: are confidence estimates trustworthy? The llmtelemetry dashboard gets a new "Calibration" tab showing reliability diagrams, Brier score trends, and per-task-type accuracy. This tab becomes part of the telemetry template for all projects.

**What already exists:**
- `record_prediction.sh` — fully working CLI with predict/outcome/list subcommands
- `~/.claude/predictions/` — JSONL data store with 6 real records (3 predictions, 3 outcomes)
- Dashboard export pattern — numbered sections in `export_dashboard_data.R`
- Dashboard tab pattern — `nav_panel()` + `renderUI()` + ECharts JS

**What's missing:** hook integration, export section, calibration computation, dashboard tab.

## Approach: 4 steps

### Step 1: Export predictions to JSON (section 10 in export script)

Add to `inst/scripts/export_dashboard_data.R` after section 7 (unified.duckdb), before section 8 (index.json):

```r
# --- 10. Export prediction calibration data ---
pred_dir <- file.path(Sys.getenv("HOME"), ".claude/predictions")
pred_files <- list.files(pred_dir, pattern = "\\.jsonl$", full.names = TRUE)
```

- Read all JSONL files, parse each line with `fromJSON()`
- Deduplicate by `prediction_id` (keep last record — outcome overwrites prediction)
- Split into resolved (outcome != null) and pending
- Compute calibration by bucket: group resolved predictions into confidence bins (0-50%, 50-70%, 70-90%, 90-100%), calculate actual success rate per bin
- Write `predictions.json` (all resolved) and `calibration_buckets.json` (aggregated)
- Add both to API index endpoints

**Files:**
- Edit: `llmtelemetry/inst/scripts/export_dashboard_data.R`

### Step 2: Dashboard Calibration tab

Add to `dashboard_shinylive.qmd`:

**Data loading:** Add `predictions.json` and `calibration_buckets.json` to YAML resources and `load_json()` calls.

**UI — new `nav_panel("Calibration")`** with 4 cards:
1. **Reliability Diagram** — scatter+line: predicted bucket midpoint (x) vs actual accuracy (y), with perfect calibration diagonal. Uses `ec_scatter()`.
2. **Brier Score Trend** — if enough data: rolling Brier score over time. Uses `ec_line()`.
3. **By Task Type** — horizontal bar: accuracy per task_type (ci_fix, feature, refactor, debug). Uses `ec_bar()`.
4. **Prediction Log** — DT table of all predictions with outcome, confidence, notes.

**Server:** 4 render functions using base R + ECharts JS (same pattern as Repo Health tab).

**Files:**
- Edit: `llmtelemetry/vignettes/dashboard_shinylive.qmd`

### Step 3: Hook integration (lightweight prompting)

**session_stop.sh** — add a check after braindump closed-loop (Phase 7):
- Scan `~/.claude/predictions/` for the current project slug
- If pending predictions exist (outcome = null), print reminder:
  ```
  PREDICTION: 2 unresolved predictions for this project:
    pred_20260314_abc: "Fix R CMD CHECK NOTE" (p=0.85)
    pred_20260315_def: "Add feature X" (p=0.70)
  Record outcomes: record_prediction.sh outcome <id> true/false
  ```
- Do NOT block — just remind (like braindump reminders)

**NOT in session_init.sh** — prediction recording should be voluntary, triggered by Claude during planning, not forced on every session start. The `skill-authoring` checklist pattern (step 7: verification) already encourages stating expected outcomes.

**Files:**
- Edit: `~/.claude/hooks/session_stop.sh`

### Step 4: Add calibration to QA validation

Add `predictions.json` to the optional files list in both:
- Export script QA (section 9) — warn if empty, don't error
- CI workflow QA step — same, optional category

**Files:**
- Edit: `llmtelemetry/inst/scripts/export_dashboard_data.R` (section 9)
- Edit: `llmtelemetry/.github/workflows/deploy-dashboard.yaml` (QA step)

## Execution Order

1. Step 1 (export) — creates the data files
2. Step 4 (QA) — validates them
3. Step 2 (dashboard) — displays them
4. Step 3 (hook) — prompts for more data collection

## Verification

1. Run export locally: `Rscript inst/scripts/export_dashboard_data.R` — verify `predictions.json` and `calibration_buckets.json` created with real data from the 3 existing predictions
2. Render dashboard locally: `quarto render vignettes/dashboard_shinylive.qmd` — verify Calibration tab appears
3. Push to CI — verify QA passes (predictions are optional, so 0 rows = warn not error)
4. Test hook: run `session_stop.sh` — verify pending prediction reminder prints
5. Record a test prediction: `record_prediction.sh predict llm llm ci_fix 0.85 "test prediction" "test"` — verify it appears in next export

## Files Summary

| Action | File |
|--------|------|
| Edit | `llmtelemetry/inst/scripts/export_dashboard_data.R` — add section 10 + QA |
| Edit | `llmtelemetry/vignettes/dashboard_shinylive.qmd` — add Calibration tab |
| Edit | `llmtelemetry/.github/workflows/deploy-dashboard.yaml` — add to QA |
| Edit | `~/.claude/hooks/session_stop.sh` — add pending prediction reminder |

## Data flow

```
record_prediction.sh predict → ~/.claude/predictions/{slug}.jsonl
                                        ↓
             export_dashboard_data.R section 10
                                        ↓
                    vignettes/data/predictions.json
                    vignettes/data/calibration_buckets.json
                                        ↓
                   dashboard Calibration tab (ECharts + DT)
                                        ↓
              session_stop.sh reminds about unresolved predictions
                                        ↓
record_prediction.sh outcome → updates JSONL → next export picks it up
```
