---
name: deslop
description: Remove AI writing patterns from prose. Use when writing, drafting, editing, or reviewing any text — vignette narratives, email templates, README.qmd, captions, issue/PR descriptions, commit messages. Trigger on "deslop", "de-AI", "make it sound human", "remove AI patterns", "clean up writing", or any prose review request.
---

# Deslop: Remove AI Writing Patterns from Prose

Strip predictable AI patterns from writing. Make prose sound like a specific human wrote it, not like a language model generated it.

## When to Apply

- Vignette prose sections (wave_analysis.qmd, dashboard_static.qmd, telemetry.qmd)
- Email templates (storm alert, weekly summary)
- README.qmd narrative
- Issue/PR descriptions
- Captions on plots, tables, and diagrams
- Any request to "make it sound human" or "deslop" writing

## Project-Specific Overrides (MANDATORY — take precedence over all deslop rules)

### Override 1: Captions MUST include specific detail

All captions on plots, tables, and diagrams MUST include:
- (a) Brief summary of what the plot/table shows
- (b) Main conclusion with specific values
- (c) Variable definitions with units (e.g., "wave height (m)", "wind speed (knots)")
- (d) Source attribution (e.g., "Source: Marine Institute ERDDAP")

This is NOT "hand-holding" — it is mandatory accessibility and reproducibility.
Deslop Rule 8 ("trust readers") does NOT override this requirement.

### Override 2: All specific values in captions AND prose MUST be dynamic

Every number, date, station name, or derived value in both captions and prose text MUST be an embedded R expression evaluated by the targets pipeline. Never hardcode values that can become stale. This applies to vignettes, emails, README, and any rendered text.

**Correct:** `paste0("Max Wave: ", round(max_hmax, 1), " m at ", max_station, " on ", max_date)`
**Wrong:** `"Max Wave: 29.9 m at M6 on 2026-03-01"`

No exceptions. Stale prose is worse than AI-sounding prose.

### Override 3: Code quality is paramount

Deslop applies ONLY to prose output. It never overrides:
- R code style (tidyverse-style skill)
- Test requirements (test-driven-development skill)
- R CMD check compliance
- Package documentation (@roxygen2 conventions)
- CLAUDE.md technical instructions

### Override 4: Bullet points are allowed

Deslop Rule 9 bans **bold-first bullets** (the AI pattern of `- **Keyword**: explanation`).
Plain bullets with direct content are fine and encouraged for lists of facts.

## Core Rules (from deslop, with overrides applied)

### 1. Cut filler phrases

Remove throat-clearing openers ("Here's the thing:"), emphasis crutches ("Let that sink in."), business jargon ("navigate the landscape"), and meta-commentary ("In this section, we'll explore..."). See [references/phrases.md](references/phrases.md).

### 2. Break formulaic structures

Avoid binary contrasts ("Not X. Y."), negative listings ("Not a X. Not a Y. A Z."), dramatic fragmentation ("Speed. That's it."), self-posed rhetorical questions ("The result? Devastating."). See [references/structures.md](references/structures.md).

### 3. Eliminate AI tropes

Watch for: "quietly", "delve", "serves as", false ranges ("from X to Y"), superficial participle analyses ("highlighting its importance"), invented concept labels, grandiose stakes inflation, patronizing analogies. See [references/tropes.md](references/tropes.md).

### 4. Use active voice with human subjects

Prefer active constructions. "The complaint becomes a fix" → "The team fixed it." In scientific vignettes, use "we" for own work. Cite specific authors, not "researchers have shown."

### 5. Be specific (REINFORCED by Override 1 and 2)

Name the specific thing with dynamic values. No vague declaratives ("The reasons are structural"). No lazy extremes ("every," "always," "never"). Domain terminology (e.g., "weighted interval score", "Beaufort scale") is precise language, not jargon.

### 6. Match register to context

- Vignette captions: precise, technical, with units and source
- Email alerts: clear, actionable, with thresholds and station names
- README: welcoming but specific, with package version and data freshness
- Issues/PRs: direct, with file paths and line numbers

### 7. Vary rhythm

Mix sentence lengths. Two items beat three. No em dashes. Do not stack short punchy fragments for manufactured emphasis.

### 8. Trust readers (with Override 1 exception)

State facts directly. Skip softening and justification. No "Let's break this down."
**EXCEPTION:** Captions MUST include summary + conclusion + units + source per Override 1. This is required context, not hand-holding.

### 9. Watch formatting tells

No bold-first bullets. No unicode arrows. No em dashes. No signposted conclusions ("In conclusion..."). No "Despite these challenges..." formulas. Plain bullets with direct content are allowed (Override 4).

### 10. Do not dilute

One point per section. Do not restate the same argument in ten different ways.

## Quick Checks

Run these before delivering any prose:

- Heavy adverbs or -ly words? Cut them.
- Passive voice? Find the actor, make them the subject.
- Inanimate thing doing a human verb? Name the person.
- "Here's what/this/that" throat-clearing? Cut to the point.
- "Not X, it's Y" contrast? State Y directly.
- Self-posed rhetorical question answered immediately? Fold into statement.
- Three consecutive sentences match length? Break one.
- Em dash anywhere? Remove it.
- Vague declarative? Name the specific implication with a dynamic value.
- "It's worth noting" or similar filler? Delete.
- Same metaphor used more than twice? Replace or cut repeats.
- "Despite these challenges..." formula? Rewrite.
- Bold-first bullet pattern? Remove bold leads.
- Tricolon (three-item list)? Use two items or one.
- **Hardcoded number or date in captions or prose?** Replace with dynamic R expression. No exceptions. (Project-specific)
- **Caption missing units or source?** Add them. (Project-specific)

## Scoring

When reviewing text, rate 1-10 on each dimension:

| Dimension | Question |
|-----------|----------|
| Directness | Statements or announcements? |
| Rhythm | Varied or metronomic? |
| Trust | Respects reader intelligence? |
| Authenticity | Sounds like a specific human wrote it? |
| Density | Anything cuttable? |

Below 35/50: revise.

## Reference Files

- [references/phrases.md](references/phrases.md): Phrases to remove or replace
- [references/structures.md](references/structures.md): Structural patterns to avoid
- [references/tropes.md](references/tropes.md): Full catalog of AI writing tropes
- [references/examples.md](references/examples.md): Before/after transformations
