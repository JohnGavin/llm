# API Design Patterns for Project Data Delivery

Reference for GitHub issue #39. Extends SKILL.md with versioning, schemas,
dynamic endpoints, CI automation, data sources, and client consumption.

---

## 1. Static JSON API via GitHub Pages

### Directory Layout

```
docs/api/v1/
  index.json                  # Endpoint catalogue
  stations.json               # Entity metadata
  stats.json                  # Summary statistics
  latest.json                 # Most recent observations
  data-dictionary.json        # Variable metadata
  erddap/buoy-summary.json   # ERDDAP-derived summaries
  genomics/projects-summary.json  # GDC project counts
  telemetry/usage-summary.json    # ccusage metrics
  schema/*.schema.json        # JSON Schema definitions
```

### Helper: Write All Endpoints

```r
write_api_endpoints <- function(endpoints, api_dir = "docs/api/v1") {
  purrr::imap_dfr(endpoints, function(data, rel_path) {
    full_path <- fs::path(api_dir, rel_path)
    fs::dir_create(fs::path_dir(full_path))
    json <- jsonlite::toJSON(
      data, pretty = TRUE, auto_unbox = TRUE,
      POSIXt = "ISO8601", Date = "ISO8601", na = "null"
    )
    writeLines(json, full_path)
    tibble::tibble(
      path = rel_path,
      size_kb = round(fs::file_size(full_path) / 1024, 1),
      n_records = if (is.data.frame(data)) nrow(data) else NA_integer_
    )
  })
}
```

---

## 2. Versioned Endpoints

| Version | Path | Status | Notes |
|---------|------|--------|-------|
| v1 | `/api/v1/` | Active | Current schema |
| v2 | `/api/v2/` | Future | Breaking changes only |

Rules:
- Additive changes (new fields/endpoints) do NOT bump the version.
- Breaking changes (removal, type change) require a new version.
- Keep at most 2 active versions. Deprecate with 90-day notice.

### Response Envelope

Every JSON response includes `_meta`:

```json
{
  "_meta": {
    "api_version": "v1",
    "generated_at": "2026-03-09T14:30:00Z",
    "generator": "llm/targets",
    "schema": "https://johngavin.github.io/llm/api/v1/schema/stats.schema.json",
    "next_update": "2026-03-16T00:00:00Z"
  },
  "data": [ ... ]
}
```

```r
api_envelope <- function(data, endpoint_name, api_version = "v1") {
  base_url <- "https://johngavin.github.io/llm/api"
  list(
    `_meta` = list(
      api_version = api_version,
      generated_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
      generator = "llm/targets",
      schema = glue::glue("{base_url}/{api_version}/schema/{endpoint_name}.schema.json"),
      next_update = format(Sys.Date() + 7L, "%Y-%m-%dT00:00:00Z")
    ),
    data = data
  )
}
```

---

## 3. Data Schemas (JSON Schema)

### Example: Station Schema

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "Station",
  "type": "object",
  "properties": {
    "_meta": { "$ref": "meta.schema.json" },
    "data": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "station_id": { "type": "string", "pattern": "^[A-Z0-9_]+$" },
          "name": { "type": "string" },
          "latitude": { "type": "number", "minimum": -90, "maximum": 90 },
          "longitude": { "type": "number", "minimum": -180, "maximum": 180 },
          "active": { "type": "boolean" },
          "first_obs": { "type": "string", "format": "date" }
        },
        "required": ["station_id", "name", "latitude", "longitude", "active"]
      }
    }
  },
  "required": ["_meta", "data"]
}
```

### Generate Schema from Data Frame

```r
generate_schema_from_df <- function(df, title, description = "") {
  r_to_json_type <- function(col) {
    if (is.integer(col)) return(list(type = "integer"))
    if (is.numeric(col)) return(list(type = "number"))
    if (is.logical(col)) return(list(type = "boolean"))
    if (inherits(col, "Date")) return(list(type = "string", format = "date"))
    if (inherits(col, "POSIXct")) return(list(type = "string", format = "date-time"))
    list(type = "string")
  }
  props <- purrr::map(df, r_to_json_type)
  for (nm in names(df)) if (anyNA(df[[nm]])) props[[nm]]$type <- list(props[[nm]]$type, "null")
  list(`$schema` = "https://json-schema.org/draft/2020-12/schema",
    title = title, type = "object",
    properties = list(`_meta` = list(`$ref` = "meta.schema.json"),
      data = list(type = "array", items = list(type = "object", properties = props,
        required = names(df)[purrr::map_lgl(df, ~ !anyNA(.x))]))))
}
```

### Validation Target

Use `jsonvalidate::json_validate()` in a target that iterates over
`docs/api/v1/schema/*.schema.json`, matches each to its data file,
validates, and `stopifnot(all(results$valid))`. See SKILL.md for the
full `api_validate_schemas` target pattern.

---

## 4. plumber2 for Dynamic Endpoints

Use only when static JSON is insufficient (parameterised queries, real-time data).

```r
library(plumber2)

#* @get /api/v1/latest
#* @param n:int Number of recent observations per entity (1-100)
#* @serializer json list(auto_unbox = TRUE, POSIXt = "ISO8601")
function(n = 1L) {
  n <- as.integer(n)
  if (n < 1L || n > 100L) cli::cli_abort("n must be between 1 and 100")
  generate_api_latest(db_path = Sys.getenv("DB_PATH"), n = n)
}

#* @get /api/v1/health
#* @serializer json list(auto_unbox = TRUE)
function() list(status = "ok", timestamp = Sys.time(), version = "v1")
```

### When to Upgrade from Static to Dynamic

| Signal | Action |
|--------|--------|
| Users need filtered queries | Add plumber2 |
| Updates more than daily | Add plumber2 + cron |
| Need authentication | Add plumber2 + API keys |
| Files exceed 5 MB each | Add pagination via plumber2 |

---

## 5. GitHub Actions for Auto-Regenerating API Data

```yaml
# .github/workflows/update-api.yml
name: Update API Data
on:
  schedule:
    - cron: '0 3 * * 1'  # Monday 03:00 UTC
  workflow_dispatch:

jobs:
  update:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: cachix/install-nix-action@v27
      - uses: cachix/cachix-action@v15
        with:
          name: johngavin
          authToken: '${{ secrets.CACHIX_AUTH_TOKEN }}'

      - name: Run targets pipeline
        run: nix-shell default.nix --run "Rscript -e 'targets::tar_make(callr_function = NULL)'"

      - name: Commit and push
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add docs/api/ || true
          git diff --cached --quiet || git commit -m "chore: update API data $(date -u +%Y-%m-%dT%H:%M:%SZ)"
          git push
```

---

## 6. Data Source Patterns

### ERDDAP (Marine Institute)

```r
fetch_erddap_summary <- function(dataset_id,
    base_url = "https://erddap.marine.ie/erddap") {
  url <- glue::glue(
    "{base_url}/tabledap/{dataset_id}.csv",
    "?station_id,latitude,longitude,time,sea_surface_temperature",
    "&time>=2025-01-01"
  )
  readr::read_csv(url, show_col_types = FALSE) |>
    dplyr::group_by(station_id) |>
    dplyr::summarise(
      n_obs = dplyr::n(), last_obs = max(time),
      mean_sst = mean(sea_surface_temperature, na.rm = TRUE),
      .groups = "drop"
    )
}
```

### GDC Genomics

```r
fetch_gdc_projects <- function(size = 100L) {
  resp <- httr2::request("https://api.gdc.cancer.gov/projects") |>
    httr2::req_url_query(
      size = size,
      fields = "project_id,name,primary_site,summary.case_count,summary.file_count"
    ) |>
    httr2::req_perform() |>
    httr2::resp_body_json()
  purrr::map_dfr(resp$data$hits, function(hit) {
    tibble::tibble(
      project_id = hit$project_id, name = hit$name,
      primary_site = paste(hit$primary_site, collapse = "; "),
      case_count = hit$summary$case_count %||% 0L,
      file_count = hit$summary$file_count %||% 0L
    )
  })
}
```

### ccusage Telemetry

```r
aggregate_ccusage <- function(log_dir = "~/.ccusage/logs") {
  fs::dir_ls(log_dir, glob = "*.jsonl") |>
    purrr::map_dfr(function(f) {
      purrr::map_dfr(readLines(f, warn = FALSE), jsonlite::fromJSON)
    }) |>
    dplyr::mutate(date = as.Date(timestamp)) |>
    dplyr::group_by(date, model) |>
    dplyr::summarise(
      n_requests = dplyr::n(),
      total_input_tokens = sum(input_tokens, na.rm = TRUE),
      total_output_tokens = sum(output_tokens, na.rm = TRUE),
      total_cost_usd = sum(cost_usd, na.rm = TRUE),
      .groups = "drop"
    )
}
```

### targets Pipeline Metadata

Use `targets::tar_meta()` to export pipeline status. Filter to completed
targets, format timestamps as ISO 8601, wrap with `api_envelope("pipeline-status")`.

---

## 7. Client-Side Consumption Patterns

### R with httr2

```r
base_url <- "https://johngavin.github.io/llm/api/v1"

stations <- httr2::request(base_url) |>
  httr2::req_url_path_append("stations.json") |>
  httr2::req_retry(max_tries = 3, backoff = ~ 2) |>
  httr2::req_cache(tempdir()) |>
  httr2::req_perform() |>
  httr2::resp_body_json()

stations_df <- purrr::map_dfr(stations$data, tibble::as_tibble)
```

### JavaScript fetch

```javascript
const BASE = 'https://johngavin.github.io/llm/api/v1';

async function fetchEndpoint(path) {
  const resp = await fetch(`${BASE}/${path}`);
  if (!resp.ok) throw new Error(`API error: ${resp.status}`);
  const json = await resp.json();
  if (json._meta?.api_version !== 'v1') {
    console.warn('Unexpected API version:', json._meta?.api_version);
  }
  return json;
}

const stations = await fetchEndpoint('stations.json');
```

### Python

```python
import requests, pandas as pd
stations = requests.get("https://johngavin.github.io/llm/api/v1/stations.json", timeout=30).json()
df = pd.DataFrame(stations["data"])
```

---

## 8. Rate Limiting and Caching Strategies

### Static API (GitHub Pages)

| Layer | Strategy | Implementation |
|-------|----------|----------------|
| Server | GitHub CDN | Automatic ~10-min TTL |
| Client (R) | `httr2::req_cache()` | `req_cache(tempdir(), max_age = 3600)` |
| Client (JS) | Service Worker | Cache-first, network-fallback |

### Reusable Cached Client

```r
api_client <- function(
    base_url = "https://johngavin.github.io/llm/api/v1",
    cache_dir = rappdirs::user_cache_dir("llm-api"),
    max_age_seconds = 3600L) {
  fs::dir_create(cache_dir)
  function(endpoint) {
    httr2::request(base_url) |>
      httr2::req_url_path_append(endpoint) |>
      httr2::req_cache(cache_dir, max_age = max_age_seconds) |>
      httr2::req_retry(max_tries = 3L, backoff = ~ 2) |>
      httr2::req_error(is_error = ~ FALSE) |>
      httr2::req_perform() |>
      httr2::resp_body_json()
  }
}

fetch <- api_client()
stations <- fetch("stations.json")
```

### ETag for Efficient Polling

```r
fetch_if_changed <- function(url, last_etag = NULL) {
  req <- httr2::request(url)
  if (!is.null(last_etag)) req <- httr2::req_headers(req, `If-None-Match` = last_etag)
  resp <- httr2::req_perform(req)
  if (httr2::resp_status(resp) == 304L) return(NULL)
  list(data = httr2::resp_body_json(resp), etag = httr2::resp_header(resp, "ETag"))
}
```

## Decision Matrix: Static vs Dynamic

| Criterion | Static (GitHub Pages) | Dynamic (plumber2) |
|-----------|----------------------|-------------------|
| Cost | Free | Server required |
| Latency | ~50ms (CDN) | ~200ms+ |
| Update frequency | Weekly/daily CI | Real-time |
| Query parameters | None | Full support |
| Authentication | None (public) | API keys, OAuth |
| Maintenance | Zero | Server monitoring |

**Start with static. Upgrade to dynamic only when specific needs arise.**
