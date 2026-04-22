---
description: Every acronym in vignette prose, tables, captions, and diagrams must be expanded on first use with an external link and have hover tooltips on subsequent uses
---

# Rule: Acronym Expansion (All Vignettes, All Projects)

## When This Applies

Every vignette, README, caption, table header, diagram label, and issue/PR description that contains an acronym.

## MANDATORY: Three Requirements Per Acronym

1. **First use**: full expansion with external link — `[cardiovascular disease (CVD)](https://www.who.int/...)`
2. **Subsequent uses**: `<abbr>` tag with tooltip — `<abbr title="Cardiovascular disease: diseases of the heart and blood vessels">CVD</abbr>`
3. **Captions**: always expand (readers may see captions without surrounding prose) — write "cardiovascular disease (CVD)" not just "CVD"

## Common Acronyms Reference

| Acronym | Expansion | Link |
|---|---|---|
| CVD | Cardiovascular disease | https://www.who.int/health-topics/cardiovascular-diseases |
| LRI | Lower respiratory infections | https://www.who.int/news-room/fact-sheets/detail/pneumonia |
| GBD | Global Burden of Disease study | https://www.healthdata.org/research-analysis/gbd |
| IHME | Institute for Health Metrics and Evaluation | https://www.healthdata.org/ |
| DALY | Disability-adjusted life year (1 DALY = 1 year of healthy life lost) | https://www.who.int/data/gho/indicator-metadata-registry/imr-details/158 |
| QALY | Quality-adjusted life year (1 QALY = 1 year in perfect health) | https://www.nice.org.uk/glossary?letter=q |
| VSL | Value of statistical life | https://www.epa.gov/environmental-economics/mortality-risk-valuation |
| LLE | Loss of life expectancy | — (define in context) |
| DfT | Department for Transport (UK) | https://www.gov.uk/government/organisations/department-for-transport |
| BLS CFOI | Bureau of Labor Statistics Census of Fatal Occupational Injuries | https://www.bls.gov/iif/oshcfoi1.htm |
| CDC | Centers for Disease Control and Prevention | https://www.cdc.gov/ |
| OWID | Our World in Data | https://ourworldindata.org/ |

## Enforcement (Future)

Add `qa_acronym_expansion` target to `plan_qa_gates.R`:
- Scan rendered HTML for bare uppercase 2-5 letter words
- Check if each has an adjacent `<abbr>` tag or first-use expansion
- Warn on unexpanded acronyms

## Forbidden

- Bare acronym on first use: "CVD is the leading killer" (no expansion)
- Acronym in caption without expansion: "CVD leads everywhere" (reader may not have read the prose)
- Acronym in table header without tooltip: column header "CVD mm/day" (no hover)
