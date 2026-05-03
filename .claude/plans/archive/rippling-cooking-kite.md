# Plan: crypto_swarms Phase 1 Completion + Phase 2 Architecture

## Context

Phase 1 MVP is working (4/4 nodes) but has three gaps: Jupiter API uses wrong version (v2→v3), no historical data, and a minimal Quarto report. Issue #1 tracks Phase 2/3 (targets/crew + Swarms SDK) but needs architectural detail.

## Step 1: Fix Jupiter API (v3)

**File:** `scripts/fetch_prices.py`

- Change URL from `api.jup.ag/price/v2` to `api.jup.ag/price/v3`
- Confirmed working: `curl "https://api.jup.ag/price/v3?ids=So111..."` returns `{usdPrice, priceChange24h, liquidity, blockId}`
- Update response parsing: no `data` wrapper, field is `usdPrice` not `price`
- Add new columns: `price_change_24h`, `liquidity`, `block_id` (Jupiter-only, null for CoinGecko)
- Keep CoinGecko fallback with try/except

**Test:** `python scripts/fetch_prices.py` → Source: Jupiter API

## Step 2: Historical Price Accumulation

**File:** `scripts/fetch_prices.py` (append logic at bottom)

- After writing `data/latest_prices.csv`, also append to `data/price_history.csv`
- If file doesn't exist → write with header; if exists → append without header
- CSV format (not Parquet) — at 3 rows/run, years before hitting performance issues
- Add `data/price_history.csv` to `.gitignore`

**File:** `src/pipeline.t` (new node)

```t
history = node(
  command = read_csv("data/price_history.csv", separator = "|"),
  serializer = ^arrow
)
```

**Test:** Run `fetch_prices.py` twice, verify `wc -l data/price_history.csv` grows.

## Step 3: Richer Quarto Report

**Root cause of current broken report:** The Nix build does sed replacement of `read_node("X")` with a bare string path. Then `.path` accessor fails. The working pattern from demos is either:
- Use `{t}` chunks that call `read_node()` without `.path` (the sed replacement gives you the path directly)
- Use `{r}` chunks with `arrow::read_ipc_file()` reading from env vars or `pipeline-output/`

**Approach:** Rewrite `src/report.qmd` with `{r}` chunks reading from `pipeline-output/` (works both in-sandbox via sed and locally for dev).

**Files to modify:**
- `src/report.qmd` — complete rewrite
- `tproject.toml` — add `ggplot2` to r-dependencies, `plotly` to py-dependencies
- `flake.nix` — mirror: add `ggplot2` to r-env, `plotly` to py-env

**Report sections:**
1. **Alert Status** — callout box with alert text from `alerts/artifact` (JSON)
2. **Latest Prices** — table from `prices/artifact` (Arrow), formatted with `knitr::kable()`
3. **Analysis** — depeg status per token, color-coded
4. **Price History** (conditional) — if `history` exists, Python plotly chart with range slider + 3-month default (user's Shiny UI rule: "Time series plots MUST have a range slider")

**Why Python plotly not R plotly:** Lighter Nix footprint. R plotly pulls in htmlwidgets + pandoc deps.

## Step 4: GitHub Issues + Phase 2 Architecture Notes

Create 3 new issues, update #1:
- **#2:** Fix Jupiter API v3
- **#3:** Historical price accumulation
- **#4:** Richer Quarto report

Update **#1** with Phase 2 architecture notes:

**targets + crew inside rn nodes:**
- targets provides parallelism (crew) but NOT caching across T runs (Nix content-addressed store gives fresh dirs)
- For caching: `tar_config_set(store = "pipeline-output/_targets")` pointing to persistent path

**Swarms SDK integration:**
- Cannot run inside Nix sandbox (needs network for LLM API calls)
- Structure as post-step: `scripts/swarms_agent.py` reads `pipeline-output/alerts/artifact`, takes action
- Pipeline becomes: `fetch_prices.py` → `t run` → `swarms_agent.py`

## Implementation Order

| Step | Scope | Commit |
|------|-------|--------|
| 1 | Jupiter v3 in fetch_prices.py | `fix: use Jupiter API v3` |
| 2 | History accumulation in fetch + new pipeline node | `feat: historical price accumulation` |
| 3 | Report rewrite + ggplot2/plotly deps | `feat: rich Quarto report with charts` |
| 4 | GitHub issues + architecture notes | `docs: Phase 2 architecture in issue #1` |

## Verification

After each step:
```bash
nix develop --command bash scripts/run.sh
```
- Step 1: "Source: Jupiter API" in terminal output
- Step 2: `wc -l data/price_history.csv` increases each run
- Step 3: `open pipeline-output/report/artifact/report.html` shows tables + chart
- Step 4: `gh issue list --repo JohnGavin/crypto_swarms` shows 4 issues
