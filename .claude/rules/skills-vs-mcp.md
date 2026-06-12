---
name: skills-vs-mcp
description: Skills STEER behavior (how an agent thinks about a problem); MCP tools DISTRIBUTE business logic (what an agent can do). Pick the right surface before authoring.
metadata:
  type: rule
paths:
  - ".claude/skills/**"
  - "**/.mcp.json"
---

# Rule: Skills vs MCP — Pick the Right Surface

## When This Applies

Every time someone proposes new agent capability — a new convention, a new check, a new external integration, a new helper, a new pattern to enforce. Before writing markdown or code, decide which surface it belongs on.

## CRITICAL: Two distinct surfaces, two distinct purposes

| Surface | Purpose | Form | Loaded when |
|---|---|---|---|
| **Skill** (`.claude/skills/<name>/SKILL.md`) | STEERS behavior — teaches the agent how to *think* about a problem | Markdown prose with optional code examples | Skill description matches the user's request OR the user types `/<skill-name>` |
| **MCP tool** (`.mcp.json` or session-attached MCP server) | DISTRIBUTES business logic — gives the agent something it can *do* via a typed tool call | Schema'd RPC endpoint exposed by an MCP server | Always available in the session once the MCP is wired |

The framing comes from Jeremiah Lowin's distinction in Show Us Your (Agent) Skills Ep 1 ([#469](https://github.com/JohnGavin/llm/issues/469)): "skills vs MCP: steering behavior vs distributing business logic."

## Decision flow

1. **Is the new capability "do this, get a result"?** (e.g. "query the DB", "open a file in an external service", "send an email") → MCP tool.
2. **Is the new capability "when you do X, think about Y first"?** (e.g. "before opening a PR, run the QA gate", "use Cleveland dot charts not pie charts", "always cite sources in the methodology block") → Skill or rule.
3. **Both?** Decompose. The "do" part is the MCP tool; the "when and how" is the skill / rule that wraps it.

## Worked examples

### Skill (steers behavior)

- [`narrative-evidence-block`](narrative-evidence-block.md) — teaches the agent to add a Methodology block at the end of every vignette
- [`accessibility`](accessibility.md) — teaches the agent to use viridis palettes, add fig-alt, meet 4.5:1 contrast
- [`survival-analysis`](../skills/survival-analysis/SKILL.md) — teaches the agent the KM → Cox → parametric baseline-first workflow
- [`pr-shipping-discipline`](pr-shipping-discipline.md) — teaches the agent that "ship it" means open a PR

These don't expose new tool calls; they constrain how existing tool calls (`Edit`, `Write`, `Bash gh pr create`) get used.

### MCP tool (distributes business logic)

- `r-btw` MCP — exposes `btw_tool_files_read`, `btw_tool_docs_help_page`, etc. — concrete operations on R sessions
- `markitdown-mcp` — exposes `convert_to_markdown` — a concrete file-format conversion
- Gmail / Calendar / Drive auth stubs — would expose RPC endpoints to send mail, read calendar, etc.

These add new capabilities; the agent could not perform them without the MCP server running.

### Both — decomposed

Suppose we want "agent should run `gp(.)` (goodpractice) on every PR pre-commit AND interpret the output against our quality-gates scoring".

- **MCP / Bash tool**: invoke `Rscript -e 'goodpractice::gp(".")'` — the *doing* part. Could be wrapped in an MCP server if we wanted typed access; otherwise it's a Bash call.
- **Skill / rule**: `goodpractice-qa` skill teaches the agent *when* to call it, *which* subset of checks to run pre-commit vs in CI, *how* to interpret the output, *what* to do on failure. The *thinking* part.

## Forbidden patterns

| Pattern | Why wrong | Fix |
|---|---|---|
| Skill that says "to do X, use this MCP that doesn't exist yet" | Skill steers a tool that isn't wired | Either build the MCP first, or rewrite the skill to use existing tools |
| MCP server that includes prose guidance in its tool descriptions trying to teach style | MCP tool descriptions are for schema and one-line documentation, not for behavioral discipline | Move the discipline into a skill or rule; keep the MCP tool description tight |
| New "skill" that's actually just an executable command | The skill surface is markdown for steering, not a binary wrapper | Build a Bash script in `.claude/scripts/` AND optionally a skill that says *when* to call it |
| New "MCP tool" that just nags about following an existing rule | MCP tools should *do* something; nagging is a hook's job | Existing rule + PreToolUse hook to enforce — not a new MCP |

## Authoring checklist

Before writing:

- [ ] Identify the *verb*. "Run gp", "open PR", "compute survival curve", "render Quarto" → MCP / Bash tool side
- [ ] Identify the *adverb*. "When", "before", "always", "never" → skill / rule side
- [ ] If both are present, decompose explicitly
- [ ] Confirm the chosen surface is in scope for what you're trying to do (see [skill-authoring](../skills/skill-authoring/SKILL.md) skill and [mcp-servers](../skills/mcp-servers/SKILL.md) skill)
- [ ] If creating a skill, the [`skill-authoring`](../skills/skill-authoring/SKILL.md) skill enforces YAML front matter, progressive disclosure, and the 500-line cap

## Relationship to existing surfaces

- [`skill-authoring`](../skills/skill-authoring/SKILL.md) skill — quality gate for new skills; assumes you've already decided the right surface is "skill" and not "MCP"
- [`mcp-servers`](../skills/mcp-servers/SKILL.md) skill — how to wire an MCP server; assumes you've already decided the right surface is "MCP"
- [`permission-discipline`](permission-discipline.md) Part 2 — MCP tool classification (read / write / destructive) — applies once a tool exists
- [`btw-timeouts`](btw-timeouts.md) — specific guard for the `r-btw` MCP; safe-tool subset

## When ambiguity remains

If after the decision flow you're still unsure, ask the user. The cost of authoring on the wrong surface is high: skills don't run without context match, MCP tools can't carry prose discipline. Better to pause than to ship the wrong shape.

## Origin

[#469](https://github.com/JohnGavin/llm/issues/469) — Show Us Your (Agent) Skills Ep 1, Jeremiah Lowin's framing (49:03 in the episode): "Skills vs MCP: steering behavior vs distributing business logic."

## Related

- [`skill-authoring`](../skills/skill-authoring/SKILL.md) skill
- [`mcp-servers`](../skills/mcp-servers/SKILL.md) skill
- [`permission-discipline`](permission-discipline.md) Part 2
- [`btw-timeouts`](btw-timeouts.md)
- [`pr-shipping-discipline`](pr-shipping-discipline.md) — companion authoring rule (this rule steers WHERE you build; that rule steers HOW shorthand maps to actions)
- [#469](https://github.com/JohnGavin/llm/issues/469) — origin
