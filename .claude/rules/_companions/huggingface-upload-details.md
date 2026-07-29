# Companion: HuggingFace Dataset Upload — Worked Code Examples

Worked code examples split out of the always-loaded
[`huggingface-upload`](../huggingface-upload.md) rule to keep it lean. The
normative content (Method Decision Table, MUST/CRITICAL statements, the
REST-API-forbidden list) stays in the rule; this file is the verbatim
commands and scripts, loaded on demand.

## Why `git+lfs` fails in CI — full explanation

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

## CLI binary verification

```bash
# Verify you have the right binary
hf --version          # huggingface_hub x.y.z
hf auth whoami        # prints your username when HF_TOKEN is set
```

## R integration — worked `system2()` call

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

## Token requirements — verification + whitespace stripping

```bash
HF_TOKEN='hf_xxx' hf auth whoami   # must print your username, not an error
```

Strip whitespace defensively when reading from secrets:

```bash
HF_TOKEN="$(echo "$HF_TOKEN" | tr -d '[:space:]')"
```

## GitHub Actions step (5-line example)

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

## Local Interactive Path — worked clone/copy/commit/push script

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

## Auth Verification — worked curl check

```bash
HF_TOKEN=$(cat ~/.cache/huggingface/token)
curl -s -H "Authorization: Bearer $HF_TOKEN" \
  "https://huggingface.co/api/datasets/owner/repo" | head -c 200
```

## DuckDB hf:// Protocol — worked query examples

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
