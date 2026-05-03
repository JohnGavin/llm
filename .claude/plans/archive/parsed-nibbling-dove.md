# Plan: #69 Falsification Table in Leaderboard + #70 Real vs Simulated Quiz

## Context

Two issues from braindumps #6, #8, #9. Both extend the falsification framework:
- #69: Embed falsification results in the leaderboard dashboard (the main strategy comparison page)
- #70: Interactive quiz where users distinguish real from simulated time series

The falsification framework is complete: 53 pipeline targets, 13 vignette targets,
standalone dashboard at docs/falsification.qmd. The leaderboard at docs/leaderboard.qmd
is the main entry point for strategy comparison but has no falsification page yet.

## Issue #69: Falsification Page in Leaderboard

### Approach: Reuse existing targets, add one page

No new targets needed. The `fals_vig_*` targets (scorecard, heatmap, alpha plot, captions)
are already built by `plan_falsification_vignette.R` and registered in `docs/_targets.R`.

### Steps

1. **Add `# Falsification` page** to `docs/leaderboard.qmd` (after Details page)
   - Tab 1: Scorecard table (`fals_vig_scorecard` + `fals_vig_scorecard_caption`)
   - Tab 2: Null rejection heatmap (`fals_vig_null_heatmap` + caption)
   - Tab 3: Alpha vs R² scatter (`fals_vig_ff_alpha_plot` + caption)
   - Tab 4: Link to full falsification dashboard
   - Each tab: intro prose sentence before code chunk (Rule 13)

2. **Strategy name mismatch**: Leaderboard has Factor MAX/DRIF/Stock/XGB/PSO;
   falsification has Avoid Worst/DRIF/Factor MAX/RSC/LTR. Partial overlap only.
   The falsification page shows its own 5 strategies — no reconciliation needed,
   but add a prose note explaining the difference.

3. **No changes to `_targets.R`** — targets already registered.

4. **Render and verify**: `quarto render docs/leaderboard.qmd`, grep for NULL/Error.

### Files Modified

| File | Change |
|------|--------|
| `docs/leaderboard.qmd` | Add `# Falsification` page with 4 tabs |

### Verification

- `quarto render docs/leaderboard.qmd` — completes without error
- Falsification page visible with scorecard, heatmap, scatter
- All values dynamic from targets (no hardcoded numbers)

---

## Issue #70: Real vs Simulated Time Series Quiz

### Approach: Pre-computed targets + static HTML/JS (no Shinylive)

Shinylive rejected because:
- `historicaldata` package not WASM-portable (uses DuckDB, Arrow, pkgload)
- Null generators are deterministic (seed-based) — pre-compute is natural
- JS is sufficient for show/hide/score/zoom UI
- Avoids 10MB+ WASM overhead

### Architecture

```
R/plan_quiz.R          → quiz_params, quiz_rounds, quiz_json targets
packages/.../R/falsification.R → hd_null_env_jump_diffusion() (NEW)
docs/quiz.qmd          → standalone dashboard, reads quiz_json
```

### Quiz Data Model

Each quiz round is a list:
```r
list(
  id          = 1L,
  difficulty  = "easy",                # easy/medium/hard/pseudo
  real_name   = "DRIF (Factor Rotation)",
  null_env    = "White Noise",
  full_real   = numeric(100),          # full-length real series (for reveal)
  full_sim    = numeric(100),          # full-length simulated series (for reveal)
  series_a    = numeric(100),          # one of {real, sim}, randomised
  series_b    = numeric(100),
  answer      = "A",                   # which series is real
  real_source = "DRIF monthly returns, 2005-2026",  # label for reveal plot
  sim_source  = "GARCH(1,1), sigma=0.20"            # label for reveal plot
)
```

**Reveal plot**: After the user guesses, show a labelled plot with both series
identified: "Real: DRIF (Factor Rotation), 2005-2026" vs "Simulated: GARCH(1,1)".
The reveal plot shows the FULL series (all 100 points) even if the user was
viewing a shorter window.

**Variable length / bonus points**: The user starts seeing only a subset of
each series (default: 100 points). A length selector offers shorter views
(50, 25, 15 points) for bonus multipliers:

| Visible length | Points multiplier | Rationale |
|----------------|-------------------|-----------|
| 100 (full)     | 1x                | Baseline  |
| 50             | 1.5x              | Harder — fewer patterns visible |
| 25             | 2x                | Much harder — trend barely detectable |
| 15             | 3x                | Near impossible — almost pure noise |

The length selector truncates from the START of the series (user sees the
most recent N points). On reveal, the full series is shown with the viewed
window highlighted.

20 rounds total: 5 easy (White Noise), 5 medium (GARCH), 5 hard (GJR-GARCH),
5 pseudo (time-reversed real data). Real series sampled from 5 fals_*_input
targets, trimmed to 100 observations.

### Steps

#### Step 0: Add jump-diffusion generator (for future "Hard+" difficulty)

Add `hd_null_env_jump_diffusion()` to `packages/historicaldata/R/falsification.R`.
Parameters: T_obs, M, lambda_annual=5, mu_jump=0, sigma_jump_annual=0.10,
sigma_annual=0.20, seed=42L. Merton jump-diffusion model.
Run `devtools::document()` to update NAMESPACE.

**Note**: Not used in initial quiz (Hard uses GJR-GARCH). Available for future
"Very Hard" difficulty level as mentioned in the issue.

#### Step 1: Create `R/plan_quiz.R`

```r
plan_quiz <- function() {
  list(
    tar_target(quiz_params, {
      list(n_rounds = 20L, T_obs = 100L, seed = 123L,
           difficulties = c("easy", "medium", "hard", "pseudo"))
    }),

    tar_target(quiz_rounds, {
      # Depends: fals_*_input targets, quiz_params, fals_vig_names
      # For each difficulty: pick 5 real series, generate 5 simulated
      # Randomise A/B order, store as list of rounds
    }),

    tar_target(quiz_json, {
      jsonlite::toJSON(quiz_rounds, auto_unbox = TRUE, digits = 6)
    })
  )
}
```

#### Step 2: Create `docs/quiz.qmd`

Quarto dashboard (same CSS/JS header as other dashboards). Structure:

- **Page 1: Quiz** — active quiz area
  - Two Plotly line charts side-by-side (Series A / Series B)
  - Length selector: 100 / 50 / 25 / 15 points (shorter = more points)
  - "A is real" / "B is real" buttons
  - Reveal: labelled plot showing full series with real/sim identified,
    viewed window highlighted, source labels (e.g., "Real: DRIF, 2005-2026")
  - Score counter: correct/total, with difficulty × length multiplier
  - Next button (+ arrow key navigation)
  - Difficulty filter dropdown

- **Page 2: Results** — after all rounds
  - Score summary by difficulty level
  - Which rounds were hardest (most incorrect)
  - Link back to falsification dashboard for methodology

- **Page 3: About** — explanation
  - What the null environments are (link to falsification methodology)
  - Why this matters (if you can't tell real from simulated, the strategy has no detectable signal)
  - Scoring: Easy=1x, Medium=2x, Hard=3x, Pseudo=4x

JS implementation:
- Parse `quiz_json` on page load
- Render two Plotly traces per round
- Click handler: compare guess to answer, update score, show reveal
- Arrow keys: Left = previous, Right = next
- Zoom slider: Plotly relayout on x-axis range

#### Step 3: Register in `docs/_targets.R`

```r
source(here::here("R/plan_quiz.R"))
# Add plan_quiz() to the c(...) call
```

#### Step 4: Build and verify

```bash
tar_make(names = c("quiz_params", "quiz_rounds", "quiz_json"))
quarto render docs/quiz.qmd
```

### Files Created/Modified

| File | Change |
|------|--------|
| `packages/historicaldata/R/falsification.R` | Add `hd_null_env_jump_diffusion()` |
| `R/plan_quiz.R` | **NEW**: quiz pipeline (3 targets) |
| `docs/quiz.qmd` | **NEW**: interactive quiz dashboard |
| `docs/_targets.R` | Source plan_quiz.R, add to c() |

### Verification

- `tar_make()` builds quiz targets without error
- `quarto render docs/quiz.qmd` produces HTML
- Quiz loads in browser: two series visible, buttons work, score tracks
- Grep HTML for NULL/Error: 0 hits
- Accessibility: arrow key navigation works, dark theme, contrast OK

---

## Implementation Order

1. **#69 first** (30 min) — just adding a page to leaderboard.qmd, no new code
2. **#70 second** (2-3 hrs) — new generator, new plan file, new dashboard with JS
