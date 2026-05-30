---
name: claude-api
description: "Build, debug, and optimize Claude API / Anthropic SDK apps. Apps built with this skill should include prompt caching. Also handles migrating existing Claude API code between Claude model versions (4.5 → 4.6, 4.6 → 4.7, retired-model replacements). TRIGGER when: code imports `anthropic`/`@anthropic-ai/sdk`; user asks for the Claude API, Anthropic SDK, or Managed Agents; user adds/modifies/tunes a Claude feature (caching, thinking, compaction, tool use, batch, files, citations, memory) or model (Opus/Sonnet/Haiku) in a file; questions about prompt caching / cache hit rate in an Anthropic SDK project. SKIP: file imports `openai`/other-provider SDK, filename like `*-openai.py`/`*-generic.py`, provider-neutral code, general programming/ML."
---

# Claude API / Anthropic SDK Skill

## Purpose

Use this skill when:
- Writing scripts that call the Anthropic Messages API directly (curl, Python, R)
- Enabling prompt caching on long, reused system prompts
- Migrating existing calls to newer Claude model versions
- Logging and tracking cache hit rates and token costs
- Optimising API costs via caching, batching, or model selection

## Prompt Caching — The Core Pattern

Anthropic charges cached tokens at ~10% of normal input cost.
Minimum cacheable block: **1024 tokens** (Haiku) or **1024 tokens** (Sonnet/Opus).
Cache lifetime: 5 minutes (default), 1 hour (extended via `cache_control`).

### When to cache

Cache a block when ALL three conditions hold:
1. The content is **static** (byte-identical) across consecutive calls
2. It is **long** (≥ 1024 tokens — roughly ≥ 4096 characters)
3. It is **reused** — the same prompt fires multiple times per session/day

Good candidates: system instructions, CLAUDE.md content, rule files, tool definitions,
fixed preambles in role prompts, codebase context injected as background.

Bad candidates: user messages with dynamic content, tool results, per-turn state.

### Placement rule

Put `cache_control` on the **last static block** before the dynamic content begins.
This maximises the cache hit surface. The cache is a prefix cache — everything up to
and including the marked block is cached; content after is NOT.

### Bash / curl example (the pattern used in this project)

```bash
# Static instructions → system block with cache_control
SYSTEM_TEXT="You are a code reviewer. <long static instructions here...>"

PAYLOAD=$(jq -n \
    --arg system_text "$SYSTEM_TEXT" \
    --arg user_content "$DYNAMIC_INPUT" \
    '{
        model: "claude-opus-4-7",
        max_tokens: 2048,
        system: [
            {
                type: "text",
                text: $system_text,
                cache_control: {type: "ephemeral"}
            }
        ],
        messages: [
            {role: "user", content: $user_content}
        ]
    }')

RESPONSE=$(curl -s https://api.anthropic.com/v1/messages \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -H "anthropic-beta: prompt-caching-2024-07-31" \
    -H "content-type: application/json" \
    -d "$PAYLOAD")
```

Note: `anthropic-beta: prompt-caching-2024-07-31` is required for older API versions.
Newer SDKs (Python ≥ 0.28, Node ≥ 0.36) handle this header automatically.

### Python SDK example

```python
import anthropic

client = anthropic.Anthropic()

SYSTEM_INSTRUCTIONS = "You are a code reviewer. <long static block ...>"

response = client.messages.create(
    model="claude-opus-4-7",
    max_tokens=2048,
    system=[
        {
            "type": "text",
            "text": SYSTEM_INSTRUCTIONS,
            "cache_control": {"type": "ephemeral"}
        }
    ],
    messages=[
        {"role": "user", "content": dynamic_user_input}
    ]
)

# Inspect cache usage
print(response.usage.cache_read_input_tokens)    # 0 on first call (cache miss)
print(response.usage.cache_creation_input_tokens) # > 0 on cache creation
```

### R (httr2) example

```r
library(httr2)

SYSTEM_TEXT <- "You are a code reviewer. <long static block ...>"

payload <- list(
  model = "claude-opus-4-7",
  max_tokens = 2048L,
  system = list(
    list(
      type = "text",
      text = SYSTEM_TEXT,
      cache_control = list(type = "ephemeral")
    )
  ),
  messages = list(
    list(role = "user", content = dynamic_input)
  )
)

resp <- request("https://api.anthropic.com/v1/messages") |>
  req_headers(
    "x-api-key"          = Sys.getenv("ANTHROPIC_API_KEY"),
    "anthropic-version"  = "2023-06-01",
    "anthropic-beta"     = "prompt-caching-2024-07-31",
    "content-type"       = "application/json"
  ) |>
  req_body_json(payload) |>
  req_perform() |>
  resp_body_json()

cat("cache_read:", resp$usage$cache_read_input_tokens, "\n")
cat("cache_creation:", resp$usage$cache_creation_input_tokens, "\n")
```

## Logging Cache Metrics (Project Convention)

Every call that has `cache_control` MUST log to `~/.claude/logs/<script>_cache.log`:

```bash
_CACHE_LOG="${HOME}/.claude/logs/my_script_cache.log"
mkdir -p "$(dirname "$_CACHE_LOG")"
printf '%s script=%s cache_read=%s cache_creation=%s input=%s output=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%S)" \
    "my_script" \
    "$(echo "$RESPONSE" | jq -r '.usage.cache_read_input_tokens // 0')" \
    "$(echo "$RESPONSE" | jq -r '.usage.cache_creation_input_tokens // 0')" \
    "$(echo "$RESPONSE" | jq -r '.usage.input_tokens // 0')" \
    "$(echo "$RESPONSE" | jq -r '.usage.output_tokens // 0')" >> "$_CACHE_LOG"
```

These logs feed `llmtelemetry` cost dashboards. See Issue #174 for tracking.

## Model Version Migration

When upgrading Claude models:

| Old model | New model | Notes |
|-----------|-----------|-------|
| `claude-opus-4-5-20251101` | `claude-opus-4-7` | Drop date suffix; shorter ID |
| `claude-sonnet-4-5-20251015` | `claude-sonnet-4-6` | Drop date suffix |
| `claude-haiku-4-5-20251001` | `claude-haiku-4-6` | Drop date suffix |

Check [Anthropic model docs](https://docs.anthropic.com/en/docs/models-overview) for
current model IDs before migrating.

## Project Call Sites (audit as of 2026-05-30)

| Script | API used | Caching | Notes |
|--------|----------|---------|-------|
| `.claude/scripts/cross_modal_eval.sh` | Anthropic Messages | Scaffolded (#174) — <1024 tokens today | Precision checker; grows with prompt |
| `.claude/scripts/detect_patterns.sh` | Anthropic Messages | Added (#174) — system block cached | Pattern detection; TOOL_SUMMARY is dynamic |

## Anti-patterns

| Pattern | Why wrong | Fix |
|---------|-----------|-----|
| Static instructions in user message | Cannot be cached | Move to system block |
| No `cache_control` on long system prompt | Paying full price every call | Add `cache_control: {type: "ephemeral"}` |
| Missing `anthropic-beta` header (older SDK) | Cache silently skipped | Add `anthropic-beta: prompt-caching-2024-07-31` header |
| Single giant message block | Puts dynamic and static together | Separate static → system, dynamic → user |
| No cache metrics logging | No visibility into savings | Log `cache_read_input_tokens` / `cache_creation_input_tokens` |
| Hardcoded model date suffix | Model IDs change | Use current model ID from docs |

## Related

- [Anthropic prompt caching docs](https://docs.anthropic.com/en/docs/build-with-claude/prompt-caching)
- Issue #174 — tracking caching rollout across project call sites
- `.claude/scripts/cross_modal_eval.sh` — reference implementation with cache_control
- `.claude/scripts/detect_patterns.sh` — updated call site (#174)
- `~/.claude/logs/cross_modal_cache.log` — cache metrics for cross_modal_eval
- `~/.claude/logs/detect_patterns_cache.log` — cache metrics for detect_patterns
