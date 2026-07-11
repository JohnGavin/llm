---
description: Every new skill, rule, or command must open with a one-line when-to-use ("press release") and a Chesterton check naming what existing surface it does NOT duplicate, before it is authored
paths:
  - ".claude/skills/**"
  - ".claude/rules/**"
  - ".claude/commands/**"
---

# Rule: Press-Release-First for New Config Surface

## Origin

[#769](https://github.com/JohnGavin/llm/issues/769) — applying David Epstein's
"Constraints, not Goals" (Tony Fadell's *"draw the box / write the press release
first"*) to our own config. The talk's core warning: **abundance breeds
sprawling, unoriginal solutions.** Our config *is* that abundance (76 rules,
73 skills, 14 commands). The constraint therefore applies to the config itself.

## When This Applies

Authoring any NEW `.claude/skills/**`, `.claude/rules/**`, or
`.claude/commands/**` file. Not for edits to existing surface (those go through
the normal review path).

## CRITICAL: State the outcome and the non-duplication BEFORE authoring

A new skill/rule/command may only be created after its author (human or agent)
can state, up front and in one or two lines each:

1. **Press release** — the one-line *when-to-use*: the concrete trigger and the
   user-facing outcome. If you cannot say in one line when this fires and what
   it changes, the surface is not ready to exist.
2. **Chesterton check** — name the *existing* rule/skill/command/hook/launchd
   job that is closest to this, and state why it does **not** already cover the
   need. "Nothing is close" is a valid answer only after you have searched
   (`grep` the rules/skills index). A hook or pulse field often already does the
   job (cf. #750, which pruned 7 commands whose deterministic core already ran
   in hooks/launchd).

If the Chesterton check finds an existing surface that covers ≥80% of the need,
**extend that surface instead of adding a new one.** Subtraction and reuse beat
addition (see `simplicity` principle in `CLAUDE.md`).

## Required header block

Every new file opens with the machinery it already needs, so the gate is
self-documenting:

- **Skills:** the `description:` frontmatter already IS the press release — it
  must lead with the trigger ("Use when …") and be specific enough to match on.
  Add a one-line `<!-- not: … -->` comment naming the nearest existing skill it
  does not duplicate.
- **Rules:** the `description:` frontmatter is the press release; a `## Origin`
  or opening line states the nearest existing rule and why this is distinct.
  (`paths:` scoping is separately mandatory — see the rule-loading enforcement
  in `CLAUDE.md`; a non-mandatory rule without `paths:` is a defect.)
- **Commands:** the command's first line states its trigger and what automated
  hook/launchd twin it is NOT (the #750 failure mode: commands that duplicate an
  already-automated path).

## Forbidden patterns

| Pattern | Why wrong | Fix |
|---|---|---|
| New rule/skill authored, justification written afterward | Accretion-first; the #769 anti-pattern | State press release + Chesterton check first |
| New command duplicating a hook/launchd/skill twin | The #750 vestigial-command failure | Extend the automated path; don't add a command |
| "Might be useful later" surface with no concrete trigger | Speculative abundance | No trigger → don't create it |
| New rule with no `paths:` scoping | Loads into every session/subagent (~250 tok/KB) | Add a real path glob (mandatory rules are the only exception) |

## Relationship to other rules

- `auto-delegation` — new rule creation is an orchestrator bounded exception; this
  rule gates *what* may be created, not *who* creates it.
- `housekeeping-framework` — the census/pruning side; this rule is the intake
  gate, housekeeping is the exit sweep. Together they bound the config surface.
- `skills-vs-mcp` — companion authoring discipline for the skill-vs-MCP choice.
- [#769](https://github.com/JohnGavin/llm/issues/769) — origin (Epstein,
  "Constraints, not Goals"; Fadell "write the press release first").
- [#750](https://github.com/JohnGavin/llm/pull/750) — the pruning that motivated
  the intake gate.
