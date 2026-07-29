---
paths: ["**/*.parquet", "**/huggingface*", "**/hf_*"]
---

# Rule: HuggingFace Dataset Upload

## When This Applies
Any project that hosts Parquet data on HuggingFace Datasets.

## Method Decision Table

| Context | Method | Why |
|---------|--------|-----|
| **CI / GitHub Actions / automation** | `hf upload` CLI | Works with `HF_TOKEN` env var; no credential-helper setup needed |
| **Local interactive** | `git clone` + `git-lfs push` | Familiar git workflow after one-time `hf auth login` |
| **REST API** | **Forbidden** | Endpoints undocumented and unreliable (see below) |

## CI / Automation Path — `hf upload` (preferred for CI)

### Why `git+lfs` fails in CI

See the companion doc for the full explanation and error text.

### CLI binary: `hf` (not `huggingface-cli`)

`huggingface-cli` is a deprecated no-op as of recent `huggingface_hub` releases
("no longer works. Use `hf`"). Always use the `hf` binary.

### Command form

```bash
hf upload <repo_id> <local_path> <path_in_repo> \
  --repo-type dataset \
  --commit-message "Update equity_daily: N tickers, M rows"
```

- `<repo_id>` — `owner/repo-name` (no `https://`, no `datasets/` prefix)
- `<local_path>` — local file or directory to upload
- `<path_in_repo>` — destination path inside the repo (`.` for repo root)
- `--repo-type` — `dataset`, `model`, or `space` (default: `model`)

### R integration: `shQuote()` is mandatory

`system2()` does not shell-quote arguments. Any argument containing spaces
(e.g. a commit message) MUST be wrapped in `shQuote()` — omitting it produces
`Got unexpected extra arguments (...)`. A worked `system2()` call is in the companion doc.

### Token requirements

The token MUST be a valid **classic Write token** (fine-grained tokens may lack
write scope for datasets). Verification and defensive whitespace-stripping
commands are in the companion doc.

### GitHub Actions step

Store the token as a GitHub Actions secret named `HF_TOKEN`. Never hardcode
it in the workflow YAML. A worked 5-line workflow step is in the companion doc.

## Local Interactive Path — `git clone` + `git-lfs push` (interactive only)

**This path requires `hf auth login` to have been run once. It does NOT work
in CI without a configured credential helper. For CI, use `hf upload` above.**

**CRITICAL:** Never embed `$HF_TOKEN` directly in a git clone URL. Tokens in URLs are:
- Visible in `ps` output
- Logged by some git versions
- Persisted in `.git/config` remote URL

A worked clone/copy/commit/push script (using `GIT_ASKPASS`, never a token in
the URL) is in the companion doc.

## Why REST API Is Forbidden

The HuggingFace REST API upload endpoints are undocumented and unreliable:
- `POST /api/upload` → 404
- `POST /api/datasets/{repo}/upload/main` → 404
- `PUT /api/datasets/{repo}/upload/main/file` → 404
- `POST /api/datasets/{repo}/commit/main` → schema errors

Use `hf upload` (CI) or `git+lfs` (local interactive) only.

## Token Location

Interactive: `~/.cache/huggingface/token` — set via `hf auth login`.
CI: `HF_TOKEN` environment variable (GitHub Actions secret).

## Auth Verification

A worked `curl` bearer-token check is in the companion doc.

## DuckDB hf:// Protocol

DuckDB reads HuggingFace Parquet natively — no download needed. The `hf://`
protocol avoids the extra HTTP redirect that `resolve/main/` URLs require, and
supports predicate pushdown (only reads matching row groups). Worked
`duckplyr::read_parquet_duckdb("hf://...")` query and preview examples are in
the companion doc.

## Metadata Sync

After uploading OHLCV data, always upload metadata too. Tickers in OHLCV without metadata rows are invisible to `hd_search()`. Use `qa_metadata_sync` target to detect drift (#19).

## Volume Data Warning

yfinance reports incorrect volume for non-US markets (known bug: ranaroussi/yfinance#300, #1610, #2302). Do NOT use raw volume for cross-exchange liquidity comparisons. Price and return data is unaffected.

## Related

- [`_companions/huggingface-upload-details.md`](_companions/huggingface-upload-details.md) — worked code examples split out of this rule
- `duckdb-patterns` skill — duckplyr for Parquet queries, security hardening
- `qa-targets-pipeline` rule — QA validation targets
