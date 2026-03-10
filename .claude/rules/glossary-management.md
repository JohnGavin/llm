---
paths:
  - "vignettes/glossary*"
  - "R/tar_plans/plan_doc_examples.R"
---
# Glossary Management Rules

## 1. CATEGORIZED TERMS (MANDATORY)

All glossary terms MUST be grouped into project-specific categories.
Categories for this project:

| Category | Scope |
|----------|-------|
| Disease & Study | Disease context, study names, data portals |
| Cytogenetics & Markers | FISH markers, translocations, deletions |
| Staging & Risk | Clinical staging systems, risk stratification |
| RNA-seq & QC | Sequencing, quality control, normalization |
| Differential Expression | DE methods, statistics, visualizations |
| Survival Analysis | Time-to-event methods, effect measures |
| Pathway & Enrichment | Gene set analysis, pathway databases |
| Data Infrastructure | Pipeline tools, build systems, documentation |

## 2. REQUIRED COLUMNS

Glossary tables MUST have these columns (in order):

1. **Term** — the term or acronym
2. **Category** — one of the categories above
3. **Definition** — concise definition with domain context
4. **Appears_In** — vignette frequency, e.g. "survival (11), exploratory (5)"
5. **See_Also** — external links (Wikipedia, PMID, package docs, project vignettes)

## 3. ORDERING

- Terms are grouped by Category
- Within each category, terms are sorted by total frequency (descending)
- If frequencies are equal, sort alphabetically

## 4. COMPLETENESS REQUIREMENTS

- ALL acronyms used in any vignette MUST appear in the glossary, regardless of frequency
- Every term MUST have at least one external link in See_Also
- External links should prefer: Wikipedia, DOI/PMID, official package docs, project vignettes

## 5. SYNC BETWEEN SOURCES

The glossary exists in two places that MUST stay synchronized:

1. `vignettes/glossary.qmd` — inline fallback data.frame
2. `R/tar_plans/plan_doc_examples.R` — `glossary_table` target

When adding or modifying terms, update BOTH files.

## 6. VIGNETTE CROSS-REFERENCES (ASPIRATIONAL)

When a glossary term is used in a vignette, it SHOULD link to the glossary:
```markdown
[ISS](glossary.html#definitions) stage III indicates advanced disease.
```
This is not enforced by hook but is recommended practice.

## Checklist

- [ ] All terms categorized
- [ ] All acronyms defined
- [ ] Every term has at least one external link
- [ ] Appears_In column populated from frequency analysis
- [ ] glossary.qmd and plan_doc_examples.R are in sync
- [ ] Terms sorted by frequency within categories
