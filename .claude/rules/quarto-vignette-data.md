---
paths:
  - "*.qmd"
  - "vignettes/**"
---
# Quarto Vignette Data Rules

All vignettes use `.qmd` format exclusively. See `quarto-vignette-format.md` Rule 0.

## 1. NO SAMPLED DATA WITHOUT EXPLICIT APPROVAL

**CRITICAL**: Never use sampled, subsetted, or filtered data in vignettes without:
1. **Explicit prior approval** from the user for EACH instance
2. **Documented justification** in the vignette itself
3. **Clear indication** to readers that data is sampled

**Violations:** `head()`, `sample_n()`, `slice()` to reduce data; filtering date ranges; using "demo" datasets.

**Correct:** Always use full production data. Pre-compute in targets for performance. If truly too large, ASK user first.

## 2. PRE-COMPUTED DATA ONLY

**MANDATORY**: Vignettes perform NO computation.

**All data from:** `targets::tar_load()`, `targets::tar_read()`, or pre-saved RDS/parquet in `inst/extdata/`.

**Forbidden:** Database queries, API calls, heavy computation (`lm()`, aggregations), file I/O that computes.

**No exceptions**: Even pipeline metadata must be pre-computed as targets. `tar_visnetwork()` only with `eval: false`. For Shinylive: pre-compute with `tar_network()` and embed JSON.

## 3. ZERO INLINE COMPUTATION OR ASSIGNMENTS

**MANDATORY**: Every `{r}` chunk is exactly ONE expression:
```r
safe_tar_read("vig_target_name")
# OR (with code provenance):
show_target("vig_target_name")
```

**Forbidden** (in non-setup chunks): `<-`, `=`, `print()`, `cat()`, `ggplot()`, `data.frame()`, `sprintf()`, `table()`, `if`/`else`, `for`, `DBI::dbGetQuery()`

**Setup chunk exception:** `knitr::opts_chunk$set()`, `library(targets)`, target store discovery, `safe_tar_read`/`show_target` definitions.

**library() rules:** Allowed: `library(targets)`, `library(DT)`. Forbidden: `library(<own-package>)`. Enforced by `vignette_check.sh`.

### Captions Are Pre-Computed in Targets

Because vignettes perform ZERO computation, captions MUST be baked into target objects. Table targets return `DT::datatable(..., caption=)`, plot targets use `labs(caption=)`. See `visualization-standards` rule for the 7-point checklist.

## 4. PKGDOWN/CI RENDERING GUARDS

**MANDATORY**: Vignettes MUST use `eval = TRUE` so `safe_tar_read()` runs in CI.

```r
in_pkgdown <- nzchar(Sys.getenv("IN_PKGDOWN"))
knitr::opts_chunk$set(eval = TRUE)  # safe_tar_read handles CI fallback
if (!in_pkgdown) library(targets)
```

**WRONG:** `eval = !in_pkgdown` — renders empty vignettes in CI.

**Post-deploy:** Grep HTML for `#> NULL`, `#> Error`, `not available`. FAIL if found.

## 4a. RDS EXPORT CHECKLIST (before every merge)

- [ ] All `vig_*` targets built: `tar_make(names = starts_with("vig_"))`
- [ ] All RDS exported to `inst/extdata/vignettes/`
- [ ] No single RDS > 2MB; total dir < 10MB
- [ ] CI build shows content (not placeholders)

## 4b. AUDIT TABLES (before every merge)

Generate two audit tables as PR evidence:

**Table 1 — Targets vs inline computation:** Count `safe_tar_read`/`show_target` chunks vs inline computation per vignette. **PASS:** violations == 0 for all.

**Table 2 — Inline computation chunks:** List every non-exempt chunk that computes inline. Exclude: setup, pkgdown-banner, session-info, eval=false. **PASS:** zero rows.

Enforced by `vignette_check.sh` hook. Violations block commit.

## 5. FULL DATE RANGE REQUIREMENT

**MANDATORY**: Time-series targets MUST use full date range.

```r
# FORBIDDEN: filter(time >= Sys.Date() - 30)
# REQUIRED:  filter(time >= as.Date("2019-01-01"))  # Or earliest available
```
