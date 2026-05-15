---
description: Every analytical vignette must end with a Methodology + Data Sources + AI Disclosure block — three required H3 subsections, no exceptions.
type: rule
name: narrative-evidence-block
---

# Rule: Narrative Evidence Block (Mandatory)

## When This Applies

Every analytical vignette (`.qmd`) in `vignettes/` or `vignettes/articles/`, any Quarto dashboard, and any published report that contains computed results or data-driven prose. Applies regardless of whether AI assisted with a particular vignette — the block is uniform, not selective.

## CRITICAL: Every Analytical Narrative Ships a Methodology Block

Analytical outputs without transparent provenance are unreliable. Readers cannot evaluate trust, reproduce the result, or identify bias without knowing where the data came from, how the analysis was structured, and whether AI assisted. A methodology block is not a formality — it is a minimum evidence standard.

## Required Structure (Mandatory)

Place `## Methodology` immediately before the bottom QR/footer include, after all content sections.

```markdown
## Methodology

### What this vignette computes

<1–3 sentences describing the specific analysis performed, what targets pipeline
objects are displayed, and the key question this page answers.>

### Data sources

- <Data source or target name>: <brief description of what it contains and how it is produced>
- <repeat for each distinct source>

### AI disclosure

This vignette was developed with assistance from Anthropic's Claude (model: Opus 4.7
and Sonnet 4.6). AI helped with code structure, prose drafting, and visualization
choices. All analytical decisions and data interpretations are the author's
responsibility.
```

## Rules for Each Subsection

### `### What this vignette computes`

- 1–3 sentences only
- Name the specific targets read (`safe_tar_read("vig_foo")`, `load_cached_ccusage()`, etc.)
- State the unit of analysis (per session, per project, per day, etc.)
- **Forbidden:** generic descriptions like "this vignette shows data"

### `### Data sources`

- Bulleted list — one bullet per distinct source
- Each bullet: `<source identifier>: <what it is and how produced>`
- Sources include: targets pipeline names (`vig_*`), log files, GitHub API queries (`gh::gh()`), DuckDB tables, ERDDAP feeds, parquet files, fallback file counts
- **Forbidden:** empty section, "see pipeline", or "various sources"

### `### AI disclosure`

The AI disclosure text is fixed — copy the skeleton exactly. No variations permitted. The model names (`Opus 4.7 and Sonnet 4.6`) should be updated if the project migrates to a different model family.

## Placement

The block goes at the END of the vignette, BEFORE the bottom QR/footer include:

```markdown
## Methodology

### What this vignette computes
...

### Data sources
...

### AI disclosure
...

{{< include ../_includes/qr-footer.qmd >}}
```

For `articles/` vignettes, the include path is `../../_includes/qr-footer.qmd`.

## QA Gate

`check_methodology_blocks(vignettes_dir, docs_dir)` in `R/tar_plans/plan_qa_gates.R` validates rendered HTML for presence of all three subsections. Pipeline fails if any rendered vignette is missing any of the three. See `plan_qa_gates.R`.

## Copy-Paste Skeleton

```markdown
## Methodology

### What this vignette computes

<Describe what this vignette computes — which targets it reads, what question it
answers, what unit of analysis is used.>

### Data sources

- `vig_*` targets from the `llm` targets pipeline, pre-computed by `tar_make()`
  and served as RDS files from `inst/extdata/vignettes/` in CI

### AI disclosure

This vignette was developed with assistance from Anthropic's Claude (model: Opus 4.7
and Sonnet 4.6). AI helped with code structure, prose drafting, and visualization
choices. All analytical decisions and data interpretations are the author's
responsibility.
```

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---------|-----------|-----|
| No methodology section | Provenance invisible to reader | Add block before footer include |
| Methodology after footer include | Excluded from rendered page | Move before `{{< include >}}` |
| "Data from the pipeline" as a source | Unactionable | Name the specific targets or files |
| Generic AI disclosure ("AI was used") | Vague | Use the fixed disclosure text above |
| Per-vignette AI disclosure variations | Inconsistent | Copy the fixed skeleton exactly |
| Missing `### AI disclosure` on AI-free vignettes | Uniform > selective | Always include; it clarifies responsibility |

## Related

- `dynamic-prose-values` — numbers in methodology text must be dynamic, not hardcoded
- `quarto-vignettes` — vignette structure rules (zero inline computation, `safe_tar_read()`)
- `narrative-colour-persistence` — colour rules for multi-panel vignettes
- `verification-before-completion` — verify block is present in rendered HTML before push
- Issue #155 — Phase 1 origin
