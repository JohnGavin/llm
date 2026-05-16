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
# Use a unique variable name to avoid shadowing system $TMPDIR
HF_WORKDIR=$(mktemp -d)

# Clone using git credential helper (avoids embedding token in URL or env).
# One-time setup: huggingface-cli login
# This stores the token in ~/.cache/huggingface/token and configures git to
# use it via the credential helper — never exposes it in ps output or history.
GIT_ASKPASS=echo git clone "https://huggingface.co/datasets/owner/repo" "$HF_WORKDIR/repo"

# If the credential helper is not configured, use GIT_ASKPASS with a helper
# script rather than embedding the token on the command line:
#   echo '#!/bin/sh; cat ~/.cache/huggingface/token' > /tmp/hf_askpass.sh
#   chmod +x /tmp/hf_askpass.sh
#   GIT_ASKPASS=/tmp/hf_askpass.sh git clone "https://..." "$HF_WORKDIR/repo"
#   rm /tmp/hf_askpass.sh
#
# NEVER use: git clone https://user:$(cat ~/.cache/huggingface/token)@...
# Tokens in URLs appear in ps output, git config remote URL, and shell history.

# Copy updated parquet(s)
cp data/dist/equity_daily.parquet "$HF_WORKDIR/repo/"

# Commit and push (LFS handles large files automatically)
git -C "$HF_WORKDIR/repo" add equity_daily.parquet
git -C "$HF_WORKDIR/repo" commit -m "Update equity_daily: N tickers, M rows"
git -C "$HF_WORKDIR/repo" push

# Clean up (safe: HF_WORKDIR is a unique temp directory we created)
rm -rf "$HF_WORKDIR"
```

**CRITICAL:** Never embed `$HF_TOKEN` directly in a git clone URL. Tokens in URLs are:
- Visible in `ps` output
- Logged by some git versions
- Persisted in `.git/config` remote URL

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
# Use duckplyr for all queries (see duckdb-patterns skill)
duckplyr::read_parquet_duckdb("hf://datasets/owner/repo/file.parquet") |>
  filter(ticker == "AAPL") |>
  collect()

# Preview first rows
duckplyr::read_parquet_duckdb("hf://datasets/owner/repo/file.parquet") |>
  head(5) |>
  collect()
```

The `hf://` protocol avoids the extra HTTP redirect that `resolve/main/` URLs require, and supports predicate pushdown (only reads matching row groups).

## Metadata Sync

After uploading OHLCV data, always upload metadata too. Tickers in OHLCV without metadata rows are invisible to `hd_search()`. Use `qa_metadata_sync` target to detect drift (#19).

## Volume Data Warning

yfinance reports incorrect volume for non-US markets (known bug: ranaroussi/yfinance#300, #1610, #2302). Do NOT use raw volume for cross-exchange liquidity comparisons. Price and return data is unaffected.

## Related

- `duckdb-patterns` skill — duckplyr for Parquet queries, security hardening
- `qa-targets-pipeline` rule — QA validation targets
