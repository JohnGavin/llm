---
paths: ["**/*.parquet", "**/huggingface*", "**/hf_*"]
---

# Rule: HuggingFace Dataset Upload

## When This Applies
Any project that hosts Parquet data on HuggingFace Datasets.

## CRITICAL: Use Git Clone + Push, Not REST API

The HuggingFace REST API upload endpoints are undocumented and unreliable:
- `POST /api/upload` → 404
- `POST /api/datasets/{repo}/upload/main` → 404
- `PUT /api/datasets/{repo}/upload/main/file` → 404
- `POST /api/datasets/{repo}/commit/main` → schema errors

**The only reliable method is git clone + git-lfs push:**

```bash
HF_TOKEN=$(cat ~/.cache/huggingface/token)
TMPDIR=$(mktemp -d)

# Clone (git-lfs pulls large files)
git clone "https://username:$HF_TOKEN@huggingface.co/datasets/owner/repo" "$TMPDIR/repo"

# Copy updated parquet(s)
cp data/dist/equity_daily.parquet "$TMPDIR/repo/"

# Commit and push (LFS handles large files automatically)
git -C "$TMPDIR/repo" add equity_daily.parquet
git -C "$TMPDIR/repo" commit -m "Update equity_daily: N tickers, M rows"
git -C "$TMPDIR/repo" push

# Clean up
rm -rf "$TMPDIR"
```

## Token Location

`~/.cache/huggingface/token` — set via `huggingface-cli login` or manually.

## Auth Verification

```bash
HF_TOKEN=$(cat ~/.cache/huggingface/token)
curl -s -H "Authorization: Bearer $HF_TOKEN" \
  "https://huggingface.co/api/datasets/owner/repo" | head -c 200
```

## DuckDB hf:// Protocol

DuckDB reads HuggingFace Parquet natively — no download needed:

```r
# R (via duckdb)
con <- DBI::dbConnect(duckdb::duckdb())
DBI::dbGetQuery(con, "SELECT * FROM read_parquet('hf://datasets/owner/repo/file.parquet') LIMIT 5")

# Or via duckplyr (zero SQL)
duckplyr::read_parquet_duckdb("hf://datasets/owner/repo/file.parquet") |>
  filter(ticker == "AAPL") |> collect()
```

The `hf://` protocol is 34% faster than resolving via `resolve/main/` URLs and supports predicate pushdown.

## Metadata Sync

After uploading OHLCV data, always upload metadata too. Tickers in OHLCV without metadata rows are invisible to `hd_search()`. Use `qa_metadata_sync` target to detect drift (#19).

## Volume Data Warning

yfinance reports incorrect volume for non-US markets (known bug: ranaroussi/yfinance#300, #1610, #2302). Do NOT use raw volume for cross-exchange liquidity comparisons. Price and return data is unaffected.

## Related Rules

- `duckdplyr-not-sql` — use duckplyr for Parquet queries
- `qa-targets-pipeline` — QA validation targets
