# Static API Deployment Skill

## When to Use

Any R package that produces derived datasets (analysis results, model outputs,
aggregated summaries) and hosts documentation on GitHub Pages.

## Architecture

```
R/api_static.R          -> Exported functions (generate_api_index, generate_api_latest)
R/tar_plans/plan_api.R  -> Targets plan producing JSON files
docs/api/v1/*.json      -> Static JSON files served via GitHub Pages
vignettes/api-usage.qmd -> Documentation vignette
```

**Data flow:** targets pipeline -> JSON files -> `docs/api/v1/` -> gh-pages -> public API

## Required Files

### 1. `R/api_static.R` (Exported Functions)

Two key functions:

- `generate_api_index(base_url, endpoints)` — Creates endpoint catalogue (index.json)
- `generate_api_latest(db_path, n = 1L)` — Queries DB for N most recent observations per entity

Both produce data suitable for `jsonlite::toJSON(pretty = TRUE, auto_unbox = TRUE)`.

### 2. `R/tar_plans/plan_api.R` (Targets Plan)

Required targets:

| Target | Source | Output |
|---|---|---|
| `api_stations` | Entity metadata function | `stations.json` |
| `api_stats` | Dashboard stats target | `stats.json` |
| `api_<derived_data>` | Analysis targets | `<derived-data>.json` |
| `api_data_dictionary` | Data dictionary function | `data-dictionary.json` |
| `api_latest` | `generate_api_latest(n=1)` | `latest.json` |
| `api_index` | `generate_api_index()` | `index.json` |
| `save_api_files` | Writes all to `docs/api/v1/` | File list + sizes |

Vignette display targets:
- `api_vignette_endpoints_dt` — `DT::datatable()` of endpoints
- `api_vignette_example_response` — Sample JSON snippet

### 3. `vignettes/api-usage.qmd` (Documentation)

Follows strict vignette rules: every chunk is ONE `safe_tar_read()` call.

Sections:
1. Overview with base URL and update schedule
2. Endpoints table (`DT::datatable`, sortable/filterable)
3. Usage examples: curl, R (jsonlite), Python (requests)
4. Bulk data access (parquet download)
5. Update schedule + CI link

Code examples stored as targets in `plan_api.R` with parse validation.

### 4. CI Integration (`weekly-update.yml`)

Add to git add step:
```yaml
git add docs/api/ || true
```

Add vignette render step:
```yaml
- name: Render api-usage vignette
  run: |
    nix-shell default.nix -A shell --run "
      cd vignettes && quarto render api-usage.qmd --output-dir ../docs/articles/
    " || echo "api-usage render failed"
```

## Endpoint Conventions

- `index.json` — Catalogue of all endpoints with URLs and descriptions
- Entity list (e.g., `stations.json`) — Metadata for all entities
- `stats.json` — Summary statistics
- Derived datasets — One file per key analysis output
- `data-dictionary.json` — Variable metadata (names, units, descriptions)
- `latest.json` — Most recent observation per entity

## JSON Serialisation

Always use:
```r
jsonlite::toJSON(
  data,
  pretty = TRUE,
  auto_unbox = TRUE,
  POSIXt = "ISO8601",
  Date = "ISO8601",
  na = "null"
)
```

## Parameterised Queries

The `generate_api_latest(db_path, n = 1L)` pattern:
- Default `n = 1L` for static JSON (one observation per entity)
- Parameterised so callers can request more (e.g., `n = 5` for last 5)
- Validates `n >= 1` with `cli::cli_abort()`
- Connects/disconnects DuckDB internally

## Table Display

Always `DT::datatable()` for interactive sorting/filtering in vignettes.
Never `knitr::kable()`.

## Phase 2 Upgrade Path

When static JSON is insufficient:
1. Add plumber server wrapping the same functions
2. Add query parameters (station, date range, n)
3. Docker deployment with plumber + DuckDB
4. Rate limiting and API keys if needed
