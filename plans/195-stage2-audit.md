# Stage 2 Audit — Path-Reference Inventory for `pkg/` Migration

**Issue:** [#363](https://github.com/JohnGavin/llm/issues/363) (sub-issue of #195)
**Date:** 2026-05-30
**Status:** Read-only audit — no files modified.
**Branch:** `chore/issue-363-stage2-audit`

This document enumerates every path/reference that would have to change when the R
package source moves from the repo root into a `pkg/` subfolder. The audit covers
the full package source tree: `R/`, `tests/`, `vignettes/`, `man/`, `inst/`,
`DESCRIPTION`, `NAMESPACE`, `_targets.R`, CI workflows, and configuration files.

---

## 1. R/ Literal Path References

Files in source code that contain an explicit `R/` directory reference.

| File | Line | Content |
|------|------|---------|
| `_targets.R` | 2 | `# Modular plans sourced from R/tar_plans/` (comment) |
| `_targets.R` | 8 | `tar_source("R/tar_plans/")` |
| `R/tar_plans/plan_structure.R` | 4 | `source(here::here("R/function_analysis.R"), local = TRUE)` |
| `R/scripts/show_usage_progress.R` | 17 | `source(here::here("R/ccusage.R"))` |
| `R/scripts/shinylive/fix_pkgdown_sw_path.R` | 14 | `#    source("R/dev/fix_pkgdown_sw_path.R")` (comment) |
| `R/scripts/shinylive/README.md` | 18 | `source("R/dev/fix_pkgdown_sw_path.R")  # If symlinked` |
| `vignettes/hover-popup-demo.qmd` | 27 | `source(here::here("R", "hover_popup_helper.R"))` |
| `vignettes/hover-popup-demo.qmd` | 91 | `source(here::here("R", "hover_popup_helper.R"))` |
| `.github/workflows/quarto-publish.yaml` | 19 | `- 'R/ccusage.R'` (push trigger path filter) |
| `.github/workflows/quarto-publish.yaml` | 96 | `# R/tar_plans/plan_qa_gates.R (...)` (comment) |
| `.github/workflows/quarto-publish.yaml` | 99 | `echo "=== HTML error scan (R/tar_plans/plan_qa_gates.R) ==="` |
| `.github/workflows/quarto-publish.yaml` | 100 | `Rscript -e 'source("R/tar_plans/plan_qa_gates.R"); scan_html_for_errors("docs")'` |

**Section summary:** 6 distinct files need editing, 12 total line references.
Highest-impact files: `_targets.R` (core pipeline entry point), `.github/workflows/quarto-publish.yaml` (4 references), `vignettes/hover-popup-demo.qmd` (2 references).

---

## 2. tests/ Literal Path References

No explicit `tests/` path literals were found in `*.R`, `*.yml`, `*.yaml`, `*.qmd`,
`*.sh`, or `*.toml` files outside the `.claude/` directory. The test runner is invoked
via standard `devtools::test()` / `testthat::test_dir()` conventions without
hard-coded path strings.

**Section summary:** 0 files need editing, 0 total line references. (No impact.)

---

## 3. system.file() Calls (Path-Sensitive)

These calls rely on the installed package's `inst/` directory. They will continue to
work if the package name remains `llm` and installation puts `inst/` under the package
prefix — the key concern is that `R CMD INSTALL .` must be run from the correct
directory after the move.

| File | Line | Content |
|------|------|---------|
| `R/ccusage.R` | 95 | `pkg_dir <- system.file("extdata", package = "llm")` |
| `tests/testthat/test-roborev-daily-email.R` | 81–83 | `system.file(".claude/scripts/send_roborev_email.R", package = "llm", ...)` |

**Risk note:** `test-roborev-daily-email.R` looks for a `.claude/scripts/` path inside
the installed package. This path is currently at repo-root (not under `inst/`), so this
call already relies on `inst/` containing a copy of `.claude/scripts/`. After the move
to `pkg/`, the `.claude/` directory will remain at the repo root — if `.claude/scripts/`
is not also copied into `pkg/inst/`, this test will silently return `""` and likely skip
or fail.

**Section summary:** 2 files need editing (or investigation), 2 total line references.
Highest-impact: `tests/testthat/test-roborev-daily-email.R` (path may already be
broken; structural risk if `.claude/` is not mirrored into `pkg/inst/`).

---

## 4. here::here() Calls

`here::here()` anchors to the repo root (the directory containing a `.here` marker or
`.git`). After moving the package into `pkg/`, the repo root does not change — `here()`
will still resolve to the repo root, not to `pkg/`. All paths built with `here::here()`
that reference package source directories (`R/`, `inst/`, `man/`) will need updating to
prepend `"pkg"`.

| File | Line | Content |
|------|------|---------|
| `R/ccusage.R` | 103 | `here::here("inst/extdata")` |
| `R/tar_plans/plan_structure.R` | 4 | `source(here::here("R/function_analysis.R"), local = TRUE)` |
| `R/tar_plans/plan_predictions.R` | 29 | `here::here("inst/extdata/llm_usage_history.duckdb")` |
| `R/tar_plans/plan_scrolly_config.R` | 80 | `claude_dir <- here::here(".claude")` |
| `R/tar_plans/plan_scrolly_config.R` | 129 | `repo_root <- here::here()` |
| `R/tar_plans/plan_vignette_outputs.R` | 30 | `here::here("inst/extdata/ccusage_blocks_all.json")` |
| `R/tar_plans/plan_vignette_outputs.R` | 145 | `here::here("inst/extdata/gemini_usage.duckdb")` |
| `R/tar_plans/plan_vignette_outputs.R` | 400 | `setwd(here::here())` |
| `R/tar_plans/plan_kb_stats.R` | 14 | `here::here("knowledge")` |
| `R/tar_plans/plan_kb_stats.R` | 100 | `here::here("inst/extdata/vignettes/vig_kb_stats.rds")` |
| `R/scripts/show_usage_progress.R` | 17 | `source(here::here("R/ccusage.R"))` |
| `vignettes/closeread-infrastructure.qmd` | 23 | `setwd(here::here())` |
| `vignettes/closeread-infrastructure.qmd` | 34 | `file.path(here::here(), "inst/extdata/vignettes")` |
| `vignettes/closeread-infrastructure.qmd` | 46–47 | `here::here(".claude", sub)` / `here::here(sub)` |
| `vignettes/telemetry.qmd` | 32 | `setwd(here::here())` |
| `vignettes/telemetry.qmd` | 43 | `file.path(here::here(), "inst/extdata/vignettes")` |
| `vignettes/config-evolution.qmd` | 59 | `here::here(".claude")` |
| `vignettes/config-evolution.qmd` | 61 | `here::here(".claude")` |
| `vignettes/hover-popup-demo.qmd` | 27 | `source(here::here("R", "hover_popup_helper.R"))` |
| `vignettes/hover-popup-demo.qmd` | 91 | `source(here::here("R", "hover_popup_helper.R"))` |
| `vignettes/articles/scrolly-config-evolution.qmd` | 24 | `setwd(here::here())` |
| `vignettes/articles/scrolly-config-evolution.qmd` | 33 | `file.path(here::here(), "inst/extdata/vignettes")` |
| `vignettes/knowledge-evolution.qmd` | 37 | `here::here("inst/extdata/vignettes/vig_kb_stats.rds")` |
| `vignettes/knowledge-evolution.qmd` | 68 | `here::here("knowledge")` |
| `vignettes/articles/closeread-config.qmd` | 32 | `setwd(here::here())` |
| `vignettes/articles/closeread-config.qmd` | 41 | `file.path(here::here(), "inst/extdata/vignettes")` |

**Section summary:** 13 distinct files need editing, 26 total line references.
Highest-impact files: `R/tar_plans/plan_vignette_outputs.R` (3 references), `vignettes/closeread-infrastructure.qmd` (3 references), `vignettes/hover-popup-demo.qmd` (2 references sourcing from `R/`).

---

## 5. devtools / usethis / rcmdcheck / pkgload Invocations

No `devtools::`, `usethis::`, `rcmdcheck::`, or `pkgload::` calls were found in
`*.R`, `*.yml`, `*.yaml`, or `*.sh` files in the package source tree (excluding `.claude/`).
The CI workflow does not use `devtools` — it uses `R CMD INSTALL` directly.

**Section summary:** 0 files need editing. (No impact.)

---

## 6. R CMD check / R CMD build / R CMD INSTALL in CI

| File | Line | Content |
|------|------|---------|
| `.github/workflows/quarto-publish.yaml` | 84 | `run: R CMD INSTALL .` |

This is the critical CI path assumption. `R CMD INSTALL .` installs the package from
the **current working directory** of the CI job. After moving to `pkg/`, this must
become `R CMD INSTALL pkg/` (or `cd pkg && R CMD INSTALL .`).

**Section summary:** 1 file needs editing, 1 total line reference.
Highest-impact: `.github/workflows/quarto-publish.yaml`.

---

## 7. Config File Locations

All config files currently live at the repo root. After Stage 2:

| File | Current path | After Stage 2 | Needs move? |
|------|-------------|---------------|-------------|
| `_pkgdown.yml` | `/` (repo root) | Should move to `pkg/_pkgdown.yml` | **Yes** |
| `_quarto.yml` | `/` (repo root) | Stays at repo root (Quarto website, not package) | No |
| `_targets.R` | `/` (repo root) | Stays at repo root (pipeline orchestrator) | No |
| `DESCRIPTION` | `/` (repo root) | Moves to `pkg/DESCRIPTION` | **Yes** |
| `NAMESPACE` | `/` (repo root) | Moves to `pkg/NAMESPACE` | **Yes** |

Note: `_quarto.yml` references vignette paths (`vignettes/*.qmd`) from the repo root;
if `vignettes/` moves into `pkg/`, the render paths in `_quarto.yml` will need updating.

**Section summary:** 3 files move (DESCRIPTION, NAMESPACE, `_pkgdown.yml`); 2 stay.
If vignettes move alongside the package, `_quarto.yml` render paths also need updating.

---

## 8. Working-Directory Assumptions in CI Workflows

No `working-directory:`, `workingDirectory:`, or `cwd:` keys were found in any
`.github/workflows/*.yml` or `*.yaml` file.

All CI steps in `quarto-publish.yaml` implicitly assume the repo root as the working
directory. This is standard GitHub Actions behaviour (`actions/checkout` sets cwd to the
repo root). The impact is that `R CMD INSTALL .` (Section 6) and `source("R/tar_plans/...")` 
in shell steps (Section 1) both assume the repo root contains the package source.

**Section summary:** 0 explicit working-directory settings found, but the implicit
assumption of repo-root-as-package-root is pervasive. Flagged as a risk in Section 13.

---

## 9. Roxygen / man References

`man/` exists at the repo root with **25 `.Rd` files**. These are generated by
`devtools::document()` from roxygen2 comments in `R/*.R` and move automatically when
`R/` moves to `pkg/R/`. No explicit `man/` path references were found in `*.R`,
`*.yml`, `*.yaml`, or `*.sh` files in the package source tree.

`man/` can be regenerated from source and does not require explicit update work.
However, any CI step that runs `devtools::document()` or `roxygen2::roxygenise()`
must be run from `pkg/`, not the repo root.

**Section summary:** 0 files need editing. (`man/` moves with `R/` automatically.)

---

## 10. Targets Pipeline Plan Paths

| File | Line | Content |
|------|------|---------|
| `_targets.R` | 8 | `tar_source("R/tar_plans/")` |
| `R/tar_plans/plan_structure.R` | 4 | `source(here::here("R/function_analysis.R"), local = TRUE)` |
| `R/scripts/show_usage_progress.R` | 17 | `source(here::here("R/ccusage.R"))` |

`tar_source("R/tar_plans/")` is the core coupling: `_targets.R` at the repo root
sourcing `R/tar_plans/` by path. After the move to `pkg/`, this must become
`tar_source("pkg/R/tar_plans/")` or the `_targets.R` must itself move into `pkg/`.

`plan_structure.R:4` uses `here::here("R/function_analysis.R")` inside a tar plan —
this is a same-directory self-reference that breaks if `R/tar_plans/` moves into
`pkg/R/tar_plans/` but `here()` still resolves to the repo root.

**Section summary:** 3 files need editing, 3 total line references.
Highest-impact: `_targets.R` (entry point for entire pipeline).

---

## 11. Per-Section Summary

| # | Section | Files needing edit | Total line refs | Top 3 most-referenced files |
|---|---------|-------------------|-----------------|----------------------------|
| 1 | R/ literals | 6 | 12 | `quarto-publish.yaml` (4), `_targets.R` (2), `hover-popup-demo.qmd` (2) |
| 2 | tests/ literals | 0 | 0 | — |
| 3 | system.file() | 2 | 2 | `R/ccusage.R`, `test-roborev-daily-email.R` |
| 4 | here::here() | 13 | 26 | `plan_vignette_outputs.R` (3), `closeread-infrastructure.qmd` (3), `hover-popup-demo.qmd` (2) |
| 5 | devtools/usethis | 0 | 0 | — |
| 6 | R CMD | 1 | 1 | `quarto-publish.yaml` |
| 7 | Config files | 3 move + 2 stay | 5 files total | `DESCRIPTION`, `NAMESPACE`, `_pkgdown.yml` |
| 8 | Working-dir CI | 0 explicit | 0 | — |
| 9 | man/ references | 0 | 0 | — |
| 10 | Targets paths | 3 | 3 | `_targets.R`, `plan_structure.R`, `show_usage_progress.R` |

---

## 12. Top-Level Summary Table

| Section | Files needing edit | Total line refs | Highest-impact file |
|---|---|---|---|
| R/ literals | 6 | 12 | `.github/workflows/quarto-publish.yaml` (4 refs) |
| tests/ literals | 0 | 0 | — |
| system.file() | 2 | 2 | `tests/testthat/test-roborev-daily-email.R` |
| here::here() | 13 | 26 | `R/tar_plans/plan_vignette_outputs.R` |
| devtools/usethis | 0 | 0 | — |
| R CMD | 1 | 1 | `.github/workflows/quarto-publish.yaml` |
| Config files | 3 (move) | 5 | `DESCRIPTION` / `NAMESPACE` |
| Working-dir CI | 0 | 0 | — |
| man/ | 0 | 0 | — |
| Targets paths | 3 | 3 | `_targets.R` |
| **TOTAL** | **~21 unique** | **~44** | `.github/workflows/quarto-publish.yaml` |

---

## 13. Risk Callouts

### 13.1 Implicit Repo-Root == Package-Root Assumption (CRITICAL)

The single biggest risk is the pervasive implicit assumption that the repo root is also
the package root. This assumption is not expressed in any one file — it is baked into:

- `R CMD INSTALL .` in CI (runs from repo root, installs from `.`)
- `tar_source("R/tar_plans/")` in `_targets.R` (relative path from repo root)
- All `here::here("inst/...")` calls (resolve to repo-root/inst/)
- All `here::here("R/...")` calls (resolve to repo-root/R/)
- `quarto render` in CI (runs from repo root, resolves `vignettes/` from there)

After moving to `pkg/`, `here::here()` will still resolve to the **repo root** (where
`.git` lives), not to `pkg/`. Every `here::here("inst/...")` and `here::here("R/...")` 
will be silently wrong — they will look for `repo-root/inst/` not `pkg/inst/`.

**Fix options:**

1. Add a `.here` file inside `pkg/` to make `here::here()` resolve to `pkg/`. This
   would break all the `.claude/`-relative paths in vignettes (e.g., `here::here(".claude")`).
2. Replace all `here::here("inst/...")` with `system.file("...", package = "llm")` —
   works after installation, breaks during development before install.
3. Use `fs::path_package("llm", "extdata")` pattern consistently.
4. Define a package-level constant `PKG_ROOT <- system.file(package = "llm")` and
   build all paths from it.

**Recommendation:** Option 4 is the safest. Requires touching ~13 files.

### 13.2 String-Building R/ Paths in plan_structure.R

`R/tar_plans/plan_structure.R:4` uses `here::here("R/function_analysis.R")` inside a
`tar_source()` call context. This is an inline string building a path to another R
source file. It will silently resolve to the wrong location after the move.

### 13.3 setwd(here::here()) Pattern (MEDIUM)

Multiple vignettes use the pattern:
```r
owd <- setwd(here::here())
on.exit(setwd(owd))
```
The intent is to set cwd to the repo root before loading `inst/extdata/` files. After
the move, `here::here()` still resolves to the repo root, so this particular use is
safe. However, it masks a deeper assumption: the vignette `safe_tar_read()` path logic
then looks for `inst/extdata/vignettes/` under the repo root, not under `pkg/inst/`.

### 13.4 R CMD INSTALL . in CI (HIGH)

`.github/workflows/quarto-publish.yaml:84` runs `R CMD INSTALL .` with the implicit
working directory being the repo root after `actions/checkout`. After Stage 2, the
package will be under `pkg/`, so this must change to `R CMD INSTALL pkg/`. This is a
single-line fix but it blocks the entire build if missed.

### 13.5 Push Trigger Path Filter (MEDIUM)

`.github/workflows/quarto-publish.yaml:19` has a push trigger path filter:
```yaml
paths:
  - 'R/ccusage.R'
```
After moving `R/ccusage.R` to `pkg/R/ccusage.R`, this filter will never fire on
changes to the file. The build would not be triggered by ccusage changes. Easy fix but
easy to forget.

### 13.6 Vignette source() Calls to R/ (MEDIUM)

`vignettes/hover-popup-demo.qmd` calls `source(here::here("R", "hover_popup_helper.R"))`
directly from a vignette chunk. This is a zero-computation rule violation *and* a
path-coupling risk. After Stage 2, this path breaks. The function should be loaded via
the installed package (it is exported), not sourced directly.

### 13.7 Targets Store Isolation

`_targets.R` uses the default `_targets/` store. If `_targets.R` moves to `pkg/`, the
store would move to `pkg/_targets/`. If it stays at the repo root (likely), the store
path is stable. Recommend keeping `_targets.R` at the repo root.

### 13.8 test-roborev-daily-email.R system.file() Path

This test calls `system.file(".claude/scripts/send_roborev_email.R", package = "llm")`.
The `.claude/` directory is at the repo root and is **not** under `inst/`. This call
will return `""` unless `.claude/scripts/` is symlinked or copied into `pkg/inst/`. The
test may already be broken; it should be investigated before Stage 2 begins.

### 13.9 R/tar_plans/plan_pkgdown.R — Plans for pkgdown Deployment

`plan_pkgdown.R` contains logic to build the pkgdown site. If `_pkgdown.yml` moves to
`pkg/`, the pkgdown build step must be run from `pkg/`. If it stays at the repo root,
pkgdown will look for `R/` relative to the repo root and fail. This plan file likely
needs updating in concert with `_pkgdown.yml`.

---

## 14. Recommended Stage 2 Work Order

Based on this audit, the following order minimises risk of cascading failures:

### Phase B-1: Investigation (Before Any Move)
1. **Clarify vignette co-location decision**: do `vignettes/` and `_quarto.yml` move
   into `pkg/` or stay at the repo root? This decision changes the scope significantly.
2. **Fix `test-roborev-daily-email.R`** `system.file()` call before the move — it may
   already be broken and will be harder to debug post-move.
3. **Decide on `_targets.R` location**: keep at repo root (recommended) or move to `pkg/`.

### Phase B-2: Package Core (Safest to Move First)
4. Move `DESCRIPTION`, `NAMESPACE` to `pkg/`.
5. Move `R/` to `pkg/R/`.
6. Move `man/` to `pkg/man/` (auto-follows `R/`).
7. Move `inst/` to `pkg/inst/`.
8. Move `tests/` to `pkg/tests/`.

### Phase B-3: Fix Path References (High-Coupling Next)
9. Update `_targets.R`: `tar_source("R/tar_plans/")` → `tar_source("pkg/R/tar_plans/")`.
10. Update `R/tar_plans/plan_structure.R:4`: update `here::here("R/function_analysis.R")` path.
11. Update all `here::here("inst/...")` calls in `R/tar_plans/*.R` to `here::here("pkg/inst/...")`.

### Phase B-4: Config Files (Medium-Coupling)
12. Move `_pkgdown.yml` to `pkg/_pkgdown.yml`.
13. Update `plan_pkgdown.R` to build from `pkg/`.

### Phase B-5: CI Workflows (Lowest Risk Last — Single Verified Change)
14. Update `.github/workflows/quarto-publish.yaml`:
    - Line 19: push trigger path filter `R/ccusage.R` → `pkg/R/ccusage.R`
    - Line 84: `R CMD INSTALL .` → `R CMD INSTALL pkg/`
    - Line 100: `source("R/tar_plans/plan_qa_gates.R")` → `source("pkg/R/tar_plans/plan_qa_gates.R")`

### Phase B-6: Vignette Fixes (Last — Render Verification Required)
15. Fix `vignettes/hover-popup-demo.qmd`: replace `source(here::here("R", ...))` with
    `requireNamespace("llm")` or directly call the exported function.
16. Update `vignettes/*.qmd` `here::here("inst/...")` references if vignettes remain
    outside `pkg/`.
17. Run `quarto render` to verify all vignettes load correctly post-move.

**Highest-risk-last rationale:** the CI workflow change (Phase B-5) is a single file,
highly reviewable, and fails fast (CI run fails immediately on merge). Vignette fixes
(Phase B-6) require a render to verify, making them slower to iterate on — do them last
when the package itself is confirmed to install correctly.
