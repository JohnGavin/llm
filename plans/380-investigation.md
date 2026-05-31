# Investigation: #380 per-review cost instrumentation

## Date
2026-05-31

## Findings

### 1. `codex_with_fallback.sh` — does it capture token counts?

**Answer: NO.** The wrapper captures exit codes, classification, duration, and
fallback metadata, but does NOT capture token counts. The codex CLI does not
expose token counts in its stdout/stderr in a structured way that this wrapper
currently reads.

The `_emit_jsonl()` function (lines 142–178) records:
```
ts, invocation_id, primary_provider, primary_exit, primary_classification,
fallback_used, fallback_provider, fallback_exit, final_provider, duration_sec,
args_redacted
```

Missing from current record: `prompt_tokens`, `completion_tokens`,
`reasoning_tokens`, `model`, `cost_usd`.

### 2. Can we get token counts from codex/gemini CLI stdout?

**codex CLI:** Does not expose token usage in a parseable format at the CLI
layer. It emits the model response text but not usage metadata.

**gemini CLI:** Similarly does not expose structured token count output at the
CLI layer.

**Decision:** Use a heuristic estimate based on the prompt/response text size
captured in the temp files. The codex CLI args are already captured (redacted).
We can estimate token count from the combined stdout character count using a
conservative approximation (4 chars ≈ 1 token for English/code text).

This is documented as an approximation. A follow-up issue (#380-follow-up) can
wire in the actual API usage endpoint response when the provider CLIs expose it.

### 3. `roborev_metrics_etl.R` — where is `roborev_agent_performance` derived?

**Function:** `build_agent_performance()` at lines 631–748.

**Key finding:** Line 742:
```r
total_cost_usd = NA_real_,   # no costs table in SQLite yet
```

This is the explicit zero-fill. The function already has the scaffold: it reads
`token_usage` from `review_jobs`, parses it, but then hard-codes `NA_real_`
for `total_cost_usd` because there is no pricing table.

### 4. `~/.claude/logs/codex_fallback/` — existing data?

**Answer:** The directory does not exist yet. PR #378 wired the wrapper into
roborev but the log directory is created on first invocation. No historical
JSONL exists today. The ETL will process future records.

### 5. llmtelemetry pricing tables — reuse path?

llmtelemetry `inst/extdata/`:
- `codex_daily.json` — codex/GPT model pricing (gpt-5.4 at ~$0.00018/1k tokens)
- `ccusage_blocks.json` — Claude usage with `costUSD` already computed

There is no standalone pricing lookup table in llmtelemetry's `inst/`. The
`export_dashboard_data.R` (lines 2507–2548) reads `total_cost_usd` directly
from the ETL output. The ETL is responsible for computing costs.

**Decision:** Embed pricing constants directly in the ETL R function. This
avoids a cross-repo dependency. Pricing constants are documented as of
2026-05-31; a separate issue will track keeping them up to date.

**Pricing constants (Anthropic, as of 2026-05-31):**
| Model prefix | $/1M input tokens | $/1M output tokens |
|---|---|---|
| `claude-opus-4` | $15.00 | $75.00 |
| `claude-sonnet-4` | $3.00 | $15.00 |
| `claude-haiku-4` | $0.80 | $4.00 |
| `claude-opus-3-7` | $15.00 | $75.00 |
| `claude-sonnet-3-7` | $3.00 | $15.00 |
| `gpt-5.4` (codex) | $0.15 | $0.60 |
| `gemini-*` | $0.075 | $0.30 |
| (default/unknown) | $3.00 | $15.00 |

Note: codex CLI uses `gpt-5.4` based on `codex_daily.json` evidence.

### 6. Token heuristic for codex/gemini fallback wrapper

Since neither CLI exposes token counts, the wrapper will:
1. Capture the byte count of stdout (the response text) via `wc -c` on the
   stdout temp file.
2. Capture the byte count of the combined args string (proxy for prompt size).
3. Emit these as `response_bytes` and `args_bytes` in the JSONL record.
4. The ETL converts bytes → approximate tokens (4 chars ≈ 1 token) and computes
   cost at the known per-model rates.

Alternative considered: query the Anthropic API `/usage` endpoint. Rejected —
requires API key in the wrapper and adds network latency to every review.

### 7. Join strategy: `codex_provider_invocations` → `roborev_review_lifecycle`

No invocation_id-to-review_id link exists. Issue #366 option (b) recommends a
±30s time-window join. This is lossy under concurrency.

**Decision for this PR:** Build the `codex_provider_invocations` table and
aggregate `total_cost_usd` into `roborev_agent_performance` using a
**time-window join** (invocation falls within the job's `started_at` →
`finished_at` window ± 60s grace). This covers the common case where one
invocation maps to one job. A follow-up issue will implement the SHA-based join
from #366 option (a).
