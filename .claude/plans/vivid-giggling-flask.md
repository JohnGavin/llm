# Plan: Single-Page Multi-Country Sea-Distance Dashboard

## Context

Parts A and B (Phases 1-2) are DONE. Ireland and UK dashboards work but are separate pages. User wants a **single URL** with a dropdown to select country/region, precomputing all data upfront.

## Completed
- [x] Part A: Visual fixes (palette, legend, captions, fonts)
- [x] Phase 1: `crs_projected` param, `get_country_boundaries()`
- [x] Phase 2: UK dashboard (England, Scotland, Wales)
- [x] Island fix: `Inf` → 0 for disconnected coastal islands

## Phase 5: Single-Page Multi-Country Dashboard (current)

### Architecture

One QMD file (`vignettes/articles/dashboard.qmd`) that:
1. **Setup chunk**: precomputes ALL country data (Ireland, England, Scotland, Wales) into a named list
2. **Tabset per region**: `{.tabset}` with one tab per country, each showing map + tables + dot plot
3. **No Shiny needed**: static HTML with Quarto tabsets (already works in dashboard format)

### Data structure
```r
regions <- list(
  Ireland  = list(counties=..., summary=..., nb_table=..., crs=2157L),
  England  = list(counties=..., summary=..., nb_table=..., crs=27700L),
  Scotland = list(counties=..., summary=..., nb_table=..., crs=27700L),
  Wales    = list(counties=..., summary=..., nb_table=..., crs=27700L)
)
```

### Why tabset over dropdown
- Static HTML: no Shiny/JS framework needed
- Quarto `{.tabset}` renders all tabs at build time — instant switching
- Leaflet widgets pre-rendered per tab — no re-computation on switch
- Each tab has its own map + tables + dot plot

### Files to modify
- `vignettes/articles/dashboard.qmd` — replace with multi-country version
- Delete `vignettes/articles/uk_dashboard.qmd` — merged into main dashboard
- `_quarto.yml` — remove UK Dashboard nav entry
- `R/sea_distance.R` — island Inf→0 fix (done)

### Dot plot height fix
- Set `fig-height: 2` (was 3) to match Table 2 vertical space

### Validation
- After precompute, assert no NA in `sea_distance` column per region
- Assert no NA in `county_name` per region
- `stopifnot()` in setup chunk — fails render if data is bad

## Verification
1. `quarto render` succeeds
2. All 4 tabs render with maps + tables
3. No NA in any caption or table
4. Dot plot height matches Table 2
5. Single URL serves all countries
