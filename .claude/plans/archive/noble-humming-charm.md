# Plan: HuggingFace Parquet Hosting for irishbuoys (#71)

## Context

The CI pipeline takes 27min because DuckDB is ephemeral — every 6-hourly run re-fetches 65,000 hours of ERDDAP data to rebuild from scratch. A Parquet export already exists (`docs/vignettes/data/buoy_data.parquet`, 6.4MB, 300K rows). Hosting it on HuggingFace makes the data publicly accessible and lays groundwork for future optimizations (reading from HF instead of rebuilding DuckDB).

This does NOT change the pipeline speed yet (that requires caching DuckDB or reading from HF — future work). This PR adds the HF infrastructure: R functions, CI upload, and compatibility tests.

## Phase 1: R package functions

**Create `R/huggingface.R`** with 3 exported functions, copying the pattern from `historicaldata` (`R/connect.R`, `R/registry.R`, `R/sample_data.R`):

- `ib_hf_url(filename = "buoy_data.parquet")` — returns `hf://datasets/{repo}/{filename}`, env var `IB_HF_REPO` with default `JohnGavin/irish-buoy-network`
- `ib_hf_online()` — curl check to HF API, returns TRUE/FALSE
- `ib_hf_connect()` — ephemeral DuckDB + httpfs for reading HF Parquet

No new DESCRIPTION dependencies needed (duckdb, DBI already in Imports).

## Phase 2: Tests

**Create `tests/testthat/test-huggingface.R`**:
- `ib_hf_url()` returns correct `hf://` string (offline test)
- `ib_hf_online()` returns logical (offline test)
- Schema snapshot: read local Parquet, snapshot column names + types
- Online test (skip_on_cran): read from HF via `ib_hf_connect()`, compare schema to local

## Phase 3: CI upload step

**Modify `.github/workflows/data-update.yml`** — add step after "Commit rendered outputs to main" (~line 258):
- Requires `HF_TOKEN` GitHub secret
- Uses git clone + git-lfs push (per global `huggingface-upload` rule, NOT REST API)
- Copies `docs/vignettes/data/buoy_data.parquet` to HF repo
- Commits with data summary message

**One-time manual setup** (not in PR):
- Create HF dataset: `huggingface-cli repo create JohnGavin/irish-buoy-network --type dataset`
- Add `.gitattributes` with LFS tracking for `*.parquet`
- Add dataset card README

## Phase 4: Documentation

- Add roxygen docs to all 3 functions
- `devtools::document()` to update NAMESPACE + man/

## Files to create/modify

| File | Action |
|------|--------|
| `R/huggingface.R` | Create |
| `tests/testthat/test-huggingface.R` | Create |
| `.github/workflows/data-update.yml` | Modify (~line 258) |
| `NAMESPACE` | Auto (document) |
| `man/ib_hf_*.Rd` | Auto (document) |

## What this does NOT change

- `R/database.R` — `connect_duckdb()`, `buoy_tbl()` unchanged
- Pipeline targets — no DAG changes
- Vignettes/dashboard — still read from targets, not HF
- Pipeline speed — still 27min (DuckDB caching is a separate issue)

## Verification

1. `devtools::check()` passes
2. `testthat::test_file("tests/testthat/test-huggingface.R")` passes
3. Manual: `ib_hf_url()` returns `"hf://datasets/JohnGavin/irish-buoy-network/buoy_data.parquet"`
4. After HF repo created + CI runs: `ib_hf_online()` returns TRUE
5. After first CI push: `arrow::read_parquet(ib_hf_url())` returns 300K+ rows
