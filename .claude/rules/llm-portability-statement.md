---
description: Visible lock-in inventory of Claude/Anthropic-specific dependencies (advisory, not a constraint)
paths:
  - "**/.mcp.json"
  - ".claude/skills/claude-api/**"
---

# Rule: LLM Portability Statement (Advisory)

## When This Applies

- When documenting a new Claude-specific feature added to this codebase
- When onboarding to the project and wanting to understand lock-in scope
- When conducting a periodic portability review or evaluating provider cost
- When a dependency on a Claude-specific API shape is introduced in code, scripts,
  or skills

## Tone: Advisory, Not a Constraint

This rule does **not** mandate portability. The codebase is Claude-only by design —
that is an explicit, accepted architectural choice (see `claude-api` skill). The
purpose of this rule is **visible lock-in**: making the dependency surface legible
so a future maintainer can make an informed decision if a provider swap is ever
considered.

Nothing in this rule requires abstracting interfaces, adding provider-neutral shims,
or removing Claude-specific features. It requires honest documentation.

## Lock-In Inventory

The table below covers every meaningful Claude/Anthropic-specific dependency in the
codebase as of 2026-06-05. Portability cost is rated Low/Medium/High.

| Feature | Where used | Anthropic-specific shape | Portability cost | Nearest OpenAI equivalent |
|---|---|---|---|---|
| **Prompt caching** (`cache_control`, `cache_read_input_tokens`) | `.claude/scripts/cross_modal_eval.sh`, `detect_patterns.sh`, `claude-api` skill | `cache_control: {type: "ephemeral"}` on system blocks; separate TTL semantics | High — OpenAI has no API-level prefix caching; would lose 90% cost savings | None (OpenAI caches automatically, no explicit control) |
| **Extended thinking** (thinking tokens, `thinking` block in response) | `claude-api` skill; any script enabling it | `thinking: {type: "enabled", budget_tokens: N}` in request body | High — no direct equivalent in most providers | OpenAI `o1`/`o3` reasoning is implicit; no explicit token budget |
| **Tool-use message format** (`tool_use` / `tool_result` content blocks) | `claude-api` skill; `roborev` scripts using structured tool calls | Anthropic's `tool_use` block shape in assistant message + `tool_result` in user message | Medium — OpenAI uses `tool_calls` / `function` format; JSON schema compatible but different field names | OpenAI `tool_calls` (requires JSON rewrite of tool result handling) |
| **Prompt caching beta header** | `.claude/scripts/cross_modal_eval.sh`, older SDK usage | `anthropic-beta: prompt-caching-2024-07-31` | Low (SDK ≥ 0.28 handles automatically; removed at migration) | N/A |
| **Model IDs** (orchestrator/worker/lightweight tier aliases — see `auto-delegation` rule's Model Tier Lookup table for current IDs) <!-- updated 2026-06; check auto-delegation rule for latest --> | `auto-delegation` rule, `CLAUDE.md` agents table, dispatching scripts | Anthropic-namespaced identifiers | Low — swap model ID strings in one place (the tier lookup table) | `gpt-4o`, `gpt-4o-mini`, `o3-mini` |
| **Claude Code harness** (Agent tool, `subagent_type=`, `isolation: "worktree"`) | `auto-delegation` rule, all dispatch scripts | Claude Code-specific tool; no API equivalent | Not portable — tied to Claude Code CLI, not the API | No equivalent; would require building an orchestrator |
| **Hooks architecture** (PreToolUse / PostToolUse / Stop event hooks) | All `.claude/hooks/*.sh` scripts | Claude Code-specific `settings.json` hook events | Not portable — tied to Claude Code CLI | No equivalent in other agent harnesses |
| **`bypassPermissions` mode** | `permission-discipline` rule, `cc.sh` wrapper | Claude Code permission modes | Not portable — CLI-specific concept | N/A |
| **Skills / SKILL.md** | `.claude/skills/*/SKILL.md` — all 65 skills | Claude Code skill description loading | Not portable — Claude Code feature; other harnesses use different injection patterns | Configurable system prompts or `AGENTS.md` in OpenAI Agents SDK |
| **`cc.sh` / `cc-worktree.sh` wrappers** | `auto-delegation` rule, `worktree-location` rule | Wrap `claude` CLI | Not portable — written for Claude Code CLI | Rewrite for target harness CLI |
| **btw R MCP** (`mcp__r-btw__*` tools) | `btw-timeouts` rule, CLAUDE.md | MCP is a cross-provider standard (Claude exposes it; other providers may too) | Low — MCP protocol is provider-neutral; the `r-btw` server is not Anthropic-specific | Any provider with MCP support could use the same server |
| **roborev** (local SQLite, `roborev` CLI) | `roborev-*` rules, session hooks | Uses Anthropic API under the hood | Medium — roborev itself would need a provider config flag | Swap `ANTHROPIC_API_KEY` for target provider key + CLI flag |
| **Anthropic API key** (`ANTHROPIC_API_KEY`) | All scripts calling the API, `.Renviron` | Environment variable name | Low — rename in `.Renviron` and scripts | `OPENAI_API_KEY` or provider equivalent |
| **System-reminder injection** | `session_init.sh` emits context blocks that Claude Code injects | Claude Code-specific `<system-reminder>` tag in context | Not portable — harness-specific injection pattern | Other harnesses use different context injection mechanisms |

## What Would Transfer Without Rewriting

| Capability | Portability | Notes |
|---|---|---|
| MCP servers (`btw`, `markitdown-mcp`) | High — MCP is an open standard | Other providers that support MCP would use these directly |
| Nix / rix environment management | Full — not model-related | Reproducible environments are provider-neutral |
| targets pipeline (`_targets.R`, plans) | Full — not model-related | R pipeline infrastructure is independent |
| Git / GitHub workflow (`gh` CLI, hooks) | Full — not model-related | Version control tooling is provider-neutral |
| `R/` package source code | Full | R packages have no LLM dependency |
| CHANGELOG, DESCRIPTION, tests | Full | Standard R package artefacts |
| DuckDB, DuckPLYR pipelines | Full | Data infrastructure is provider-neutral |
| Knowledge base (`wiki/`, `raw/`) | Full | Markdown files; model-agnostic |

## What We Explicitly Do Not Port

The following are Claude Code harness features, not model features. They exist
because this project is built on Claude Code and would need to be rebuilt from
scratch for any other harness — the cost is architectural, not a matter of
swapping IDs.

- Agent tool with `subagent_type` / `isolation: "worktree"` — Claude Code orchestration
- PreToolUse / PostToolUse / Stop hooks — Claude Code event model
- Skill files (SKILL.md) — Claude Code skill loading
- Session-init / session-stop lifecycle — Claude Code session events
- `bypassPermissions` mode — Claude Code permission model

These are load-bearing parts of the development workflow. A provider swap would
require redesigning the agentic workflow, not just swapping an API key.

## When This Rule Is Updated

Update the Lock-In Inventory table when:

1. A new Claude API feature is adopted (prompt caching, thinking, files, citations…)
2. A model ID is changed (migration, retirement)
3. A portability investigation is conducted — add findings inline
4. A harness feature is added or removed from the workflow

## Patterns That Warrant a Note Here (Not Forbidden)

These patterns are perfectly fine to use; they just increase lock-in and should be
noted if added:

| Pattern | Why it increases lock-in |
|---|---|
| Hardcoded `claude-*` model IDs in R scripts (not just dispatch rules) | Spreads model IDs across the codebase; more places to update on migration |
| Claude-specific API features (extended thinking, citations) in production R functions | Moves lock-in from scripts into package exports |
| Roborev as a CI quality gate | Ties CI to Anthropic API availability |

## Related

- `claude-api` skill — the companion "how to build with Claude" guide; this rule
  is the "what that costs in portability" half
- `external-code-zero-trust` — supply chain; adjacent concern
- `auto-delegation` rule — the Model Tier Lookup table is the single source of truth for current model IDs (orchestrator/worker/lightweight tiers); the primary model-ID lock-in point
- `btw-timeouts` rule — `r-btw` MCP usage; MCP itself is portable
- `permission-discipline` — `bypassPermissions` mode; Claude Code-specific
- `mcp-servers` skill — MCP is an open standard; see as a portability win
- Issue #478 — origin
- Issue #450 — parent Salesforce 8 Design Principles gap analysis (Principle 8)
