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

`git+lfs` push over HTTPS requires a credential helper to supply the token.
In CI, the token is available as an environment variable but git's LFS smart-HTTP
protocol falls back to HTTP Basic auth, producing:

```
remote: Password authentication in git is no longer supported.
You must use a user access token with the appropriate scope.
```

This error fires regardless of whether the git username is the token itself or
the account name, because HuggingFace's LFS endpoint rejects HTTP Basic auth
altogether. The `hf` CLI bypasses this by posting via the HuggingFace Hub REST
client which authenticates with Bearer tokens natively.

### CLI binary: `hf` (not `huggingface-cli`)

`huggingface-cli` is a deprecated no-op as of recent `huggingface_hub` releases
("no longer works. Use `hf`"). Always use the `hf` binary.

```bash
# Verify you have the right binary
hf --version          # huggingface_hub x.y.z
hf auth whoami        # prints your username when HF_TOKEN is set
```

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
(e.g. a commit message) MUST be wrapped in `shQuote()`:

```r
system2("hf", args = c(
  "upload",
  shQuote(repo_id),
  shQuote(local_path),
  ".",
  "--repo-type", "dataset",
  "--commit-message", shQuote(commit_msg)
))
```

Omitting `shQuote()` produces: `Got unexpected extra arguments (...)`.

### Token requirements

The token MUST be a valid **classic Write token** (fine-grained tokens may lack
write scope for datasets). Verify before storing:

```bash
HF_TOKEN='hf_xxx' hf auth whoami   # must print your username, not an error
```

Strip whitespace defensively when reading from secrets:

```bash
HF_TOKEN="$(echo "$HF_TOKEN" | tr -d '[:space:]')"
```

### GitHub Actions step (5-line example)

```yaml
- name: Upload dataset to HuggingFace
  env:
    HF_TOKEN: ${{ secrets.HF_TOKEN }}
  run: |
    pip install --quiet --upgrade huggingface_hub
    hf upload owner/my-dataset data/dist/equity_daily.parquet equity_daily.parquet \
      --repo-type dataset \
      --commit-message "CI update $(date -u +%Y-%m-%dT%H:%M:%SZ)"
```

Store the token as a GitHub Actions secret named `HF_TOKEN`. Never hardcode
it in the workflow YAML.

## Local Interactive Path — `git clone` + `git-lfs push` (interactive only)

**This path requires `hf auth login` to have been run once. It does NOT work
in CI without a configured credential helper. For CI, use `hf upload` above.**

```bash
# Use a unique variable name to avoid shadowing system $TMPDIR
HF_WORKDIR=$(mktemp -d)

# Clone using git credential helper (avoids embedding token in URL or env).
# One-time setup: hf auth login
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
