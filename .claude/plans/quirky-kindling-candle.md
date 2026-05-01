# Plan: Rebuild Death Shares Vignette as Standalone Pure-JS App

## Context

The current `death_shares_shinylive.qmd` has multiple issues:
- **Name:** "Death Shares" is meaningless jargon — rename to "Causes of Death by Country"
- **Format:** Shinylive (30-60s WASM load, embedded in pkgdown chrome) — convert to pure JS like `micromort-quiz.qmd` for instant load
- **Navbar:** Listed under Quizzes (Shinylive) section — move to Analysis
- **UI:** Missing tabset, no hover popups, redundant legend, no linked causes, no notes/references

## Changes

### 1. Rename and reformat the vignette

**File:** `vignettes/death_shares_shinylive.qmd` → replace entirely with `vignettes/causes_of_death.qmd`

- **Title:** "Causes of Death by Country"
- **Format:** Pure HTML/CSS/JS in `{=html}` blocks (no `filters: - shinylive`)
- **YAML:** Match `micromort-quiz.qmd` pattern — `format: html:`, `page-layout: full`, `embed-resources: false`
- **Data:** Embed `death_shares.csv` as JSON in a `<script type="text/plain" id="death-data">` tag (same pattern as quiz vignettes)

### 2. Three-tab tabset UI

Pure JS tabs (same pattern as introduction.qmd dashboard tabs):

| Tab | Content |
|-----|---------|
| **Chart** | CSS treemap (keep existing design), NO legend, hover shows table-row detail |
| **Table** | Sortable HTML table with linked cause names and category names |
| **Notes** | Bullet summary, exclusions (Ireland), data sources with dates, glossary |

### 3. Chart tab improvements

- **Remove legend** — colours are labelled directly on treemap cells
- **Add hover popup** — on mouseover, show a positioned tooltip div with: cause name, category, deaths/100k, share %, and a link to the cause's external page
- **Country selector** at top (dropdown) + optional comparison toggle

### 4. Table tab improvements

- Sortable columns (pure JS, no DT/Shinylive needed)
- **Cause column:** Each cause name is an `<a href>` link to authoritative external page
- **Category column:** Each category links to WHO NCD or infectious disease overview

### 5. Cause → URL mapping

Built from existing project references + WHO pages:

| Cause | URL |
|-------|-----|
| Cardiovascular diseases | https://www.who.int/health-topics/cardiovascular-diseases |
| Neoplasms | https://www.who.int/health-topics/cancer |
| Chronic respiratory diseases | https://www.who.int/health-topics/chronic-respiratory-diseases |
| Diabetes mellitus | https://www.who.int/health-topics/diabetes |
| Chronic kidney disease | https://www.who.int/health-topics/kidney-diseases |
| Chronic liver disease | https://www.who.int/health-topics/hepatitis |
| Digestive diseases | https://www.who.int/health-topics/noncommunicable-diseases |
| Lower respiratory infections | https://www.who.int/news-room/fact-sheets/detail/pneumonia |
| Diarrheal diseases | https://www.who.int/news-room/fact-sheets/detail/diarrhoeal-disease |
| Tuberculosis | https://www.who.int/health-topics/tuberculosis |
| HIV/AIDS | https://www.who.int/health-topics/hiv-aids |
| Malaria | https://www.who.int/health-topics/malaria |
| Hepatitis | https://www.who.int/health-topics/hepatitis |
| Meningitis | https://www.who.int/health-topics/meningitis |

Category links:
- Non-communicable → https://www.who.int/health-topics/noncommunicable-diseases
- Infectious → https://www.who.int/health-topics/infectious-diseases

### 6. Notes tab content

Structured as:

**Data summary:**
- 26 countries (top 20 by population + OECD members)
- 14 causes: 7 non-communicable + 7 infectious
- Source: IHME Global Burden of Disease 2019 via [Our World in Data](https://ourworldindata.org/causes-of-death) (catalog snapshot 2024-05-20)
- Age-standardised death rates per 100,000 population

**Exclusions:**
- **Ireland:** Listed in download script but absent from bundled data — see [#94](https://github.com/JohnGavin/micromort/issues/94)
- **Injuries** (road accidents, suicide, violence): Not included — see [#91](https://github.com/JohnGavin/micromort/issues/91)
- **Maternal/neonatal deaths:** Not included
- Shares sum to 100% of the 14 tracked causes, NOT 100% of all-cause mortality

**Staleness:**
- GBD data year: **2019** (latest in bundled snapshot)
- OWID catalog date: **2024-05-20** (now returns 404 — [#94](https://github.com/JohnGavin/micromort/issues/94))
- GBD 2023 available from IHME but requires account — [#90](https://github.com/JohnGavin/micromort/issues/90)

**Glossary:** (with embedded links)
- GBD, IHME, OWID, NCD, CVD, LRI, DALY — per acronym-expansion rule

### 7. Navbar changes

**File:** `_pkgdown.yml`

- Remove from current Quizzes (Shinylive) section
- Add to Analysis section:
  ```yaml
  - text: "Causes of Death by Country"
    href: articles/causes_of_death.html
  ```
- Update articles listing: remove `death_shares_shinylive`, add `causes_of_death`

### 8. Cleanup

- Delete `vignettes/death_shares_shinylive.qmd`
- Delete `docs/articles/death_shares_shinylive.html` and `death_shares_shinylive_files/`
- Keep `inst/extdata/death_shares.csv` and `data-raw/generate_death_shares_csv.R` (unchanged)

## Files modified

| File | Action |
|------|--------|
| `vignettes/causes_of_death.qmd` | CREATE — pure JS vignette with 3 tabs |
| `vignettes/death_shares_shinylive.qmd` | DELETE |
| `_pkgdown.yml` | EDIT — move article from Quizzes to Analysis, rename |
| `docs/articles/death_shares_shinylive*` | DELETE (old build artifacts) |
| `docs/articles/causes_of_death.html` | CREATE (build output) |

## Implementation approach

- Build the entire vignette as one `{=html}` block containing:
  - Inline CSS (dark theme matching existing vignettes)
  - Inline JS that reads embedded JSON data, renders treemap, table, and notes
  - Country dropdown + comparison toggle
  - Tab switching via plain button click handlers (same as introduction.qmd)
- Data: convert `death_shares.csv` to JSON array, embed in `<script type="application/json">`
- Treemap: keep the existing CSS flex-based design, add tooltip div positioned on hover
- Table: pure HTML `<table>` with JS sort-on-click headers
- No Shinylive, no R runtime, no WASM — instant load

## Verification

1. `quarto render vignettes/causes_of_death.qmd` succeeds
2. `pkgdown::build_article("causes_of_death")` succeeds
3. Open in browser — loads instantly (no WASM wait)
4. Country dropdown works, comparison mode works
5. Hover over treemap cell → tooltip shows cause detail
6. Table cause/category names are clickable links
7. Notes tab has all exclusions, sources, staleness dates
8. Navbar shows article under Analysis section
