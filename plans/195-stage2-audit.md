# Stage 2 Audit — Path-Reference Inventory for `pkg/` Migration

> **DO NOT START PHASE B/C/D YET — needs dedicated session with manual smoke-tests.**
> This document is the read-only Phase A audit output. Phases B–D are deferred.

**Issue:** [#363](https://github.com/JohnGavin/llm/issues/363) (sub-issue of [#195](https://github.com/JohnGavin/llm/issues/195))
**Date:** 2026-06-01 (v2 — updated from v1 2026-05-30)
**Status:** Read-only audit — no files modified.
**Branch:** `chore/issue-363-stage2-audit-v2`

This document enumerates every path/reference that would have to change when the R
package source moves from the repo root into a `pkg/` subfolder. The audit covers
the full package source tree: `R/`, `tests/`, `vignettes/`, `man/`, `inst/`,
`DESCRIPTION`, `NAMESPACE`, `_targets.R`, CI workflows, and configuration files.

v2 adds: (a) new findings in `tests/testthat/test-roborev-revalidate.R`, (b) new
`list.files("R/...")` references in `plan_vignette_outputs.R`, (c) complete coverage
of `wiki-sync-check.yaml` (not present at v1 audit time), and (d) the verbatim
Phase B–D plan from the issue body.

---

## 1. R/ Literal Path References

Files in source code (outside `.claude/`) that contain an explicit `R/` directory
reference. Excludes `.claude/` (agent tooling, not package source).

| File | Line | Content |
|------|------|---------|
| `_targets.R` | 2 | `# Modular plans sourced from R/tar_plans/` (comment) |
| `_targets.R` | 8 | `tar_source("R/tar_plans/")` |
| `R/tar_plans/plan_structure.R` | 4 | `source(here::here("R/function_analysis.R"), local = TRUE)` |
| `R/tar_plans/plan_vignette_outputs.R` | 406 | `plan_files <- list.files("R/tar_plans", pattern = "^plan_.*\\.R$", full.names = TRUE)` |
| `R/tar_plans/plan_vignette_outputs.R` | 651 | `r_files <- list.files("R", pattern = "\\.R$", full.names = TRUE, recursive = TRUE)` |
| `R/tar_plans/plan_vignette_outputs.R` | 652 | `r_files <- r_files[!grepl("R/dev/", r_files, fixed = TRUE)]` |
| `R/tar_plans/plan_vignette_outputs.R` | 655 | `plan_files <- list.files("R/tar_plans", pattern = "^plan_.*\\.R$")` |
| `R/scripts/shinylive/fix_pkgdown_sw_path.R` | 14 | `#    source("R/dev/fix_pkgdown_sw_path.R")` (comment) |
| `R/scripts/shinylive/README.md` | 18 | `source("R/dev/fix_pkgdown_sw_path.R")  # If symlinked` |
| `R/scripts/show_usage_progress.R` | 17 | `source(here::here("R/ccusage.R"))` |
| `.github/workflows/quarto-publish.yaml` | 19 | `- 'R/ccusage.R'` (push trigger path filter) |
| `.github/workflows/quarto-publish.yaml` | 96 | `# R/tar_plans/plan_qa_gates.R (...)` (comment) |
| `.github/workflows/quarto-publish.yaml` | 99 | `echo "=== HTML error scan (R/tar_plans/plan_qa_gates.R) ==="` |
| `.github/workflows/quarto-publish.yaml` | 100 | `Rscript -e 'source("R/tar_plans/plan_qa_gates.R"); scan_html_for_errors("docs")'` |
| `.github/workflows/wiki-sync-check.yaml` | 2 | `# run \`Rscript R/dev/wiki/sync_wiki.R\` locally to fix` (comment) |
| `.github/workflows/wiki-sync-check.yaml` | 15 | `- 'R/dev/wiki/sync_wiki.R'` (push trigger path filter) |
| `.github/workflows/wiki-sync-check.yaml` | 22 | `- 'R/dev/wiki/sync_wiki.R'` (pull_request trigger path filter) |
| `.github/workflows/wiki-sync-check.yaml` | 47 | `source("R/dev/wiki/sync_wiki.R", local = TRUE, chdir = FALSE)` |
| `.github/workflows/wiki-sync-check.yaml` | 133 | `echo "  Rscript R/dev/wiki/sync_wiki.R"` (error message) |
| `vignettes/hover-popup-demo.qmd` | — | No `source(here::here("R", ...))` calls present in v2 (removed since v1 audit) |

**Section summary:** 7 distinct files need editing, 18 total active line references
(excluding the comment lines and the hover-popup-demo.qmd which is now clean).
Highest-impact: `.github/workflows/quarto-publish.yaml` (4 active refs),
`wiki-sync-check.yaml` (4 active refs — new since v1 audit),
`R/tar_plans/plan_vignette_outputs.R` (4 refs — 3 new since v1 audit).

---

## 2. tests/ Literal Path References

Test files that reference `"R/..."` as string literals (excluding `"R/foo.R"` used
as generic test fixture strings in `test-roborev-revalidate.R`).

| File | Line | Content | Type |
|------|------|---------|------|
| `tests/testthat/test-roborev-revalidate.R` | 103 | `expect_equal(r1$path, "R/foo.R")` | Test fixture string |
| `tests/testthat/test-roborev-revalidate.R` | 106 | `r2 <- parse_location("R/bar.R:10-15")` | Test fixture string |
| `tests/testthat/test-roborev-revalidate.R` | 107 | `expect_equal(r2$path, "R/bar.R")` | Test fixture string |
| `tests/testthat/test-roborev-revalidate.R` | 270 | `primary_loc = "R/foo.R:10-20"` | Test fixture string |
| `tests/testthat/test-roborev-revalidate.R` | 274 | `finding = list(severity = "High", location = "R/foo.R:10", ...)` | Test fixture string |
| `tests/testthat/test-roborev-revalidate.R` | 340 | `primary_loc = "R/foo.R:1"` | Test fixture string |

**Assessment:** All six occurrences in `test-roborev-revalidate.R` are **test fixture
strings** — they represent synthetic `R/foo.R` paths passed to `parse_location()` to
test the parser's ability to handle the `R/<file>:<line>` format. These are NOT
references to actual files in `R/`. After Stage 2 they will remain valid because
`parse_location()` accepts any path string; these tests do not check whether the
path exists on disk.

**Section summary:** 0 files need editing, 0 actionable line references.
(The 6 string literals are test fixtures, not live path bindings.)

---

## 3. system.file() Calls (Path-Sensitive)

These calls rely on the installed package's directory structure. They will continue to
work if the package name remains `llm` and installation puts `inst/` under the package
prefix — the key concern is that `R CMD INSTALL .` must be run from the correct
directory after the move.

| File | Line | Content |
|------|------|---------|
| `R/ccusage.R` | 95 | `pkg_dir <- system.file("extdata", package = "llm")` |
| `tests/testthat/test-roborev-daily-email.R` | 82–85 | `system.file("scripts/send_roborev_email.R", package = "llm", mustWork = FALSE)` |
| `tests/testthat/test-roborev-daily-email.R` | 182–185 | `system.file("scripts/send_roborev_email.R", package = "llm", mustWork = FALSE)` (second test) |

**Risk note:** `test-roborev-daily-email.R` looks for `scripts/send_roborev_email.R`
inside the installed package (i.e. under `inst/scripts/`). The test has a dev-time
fallback via `normalizePath(file.path(dirname(dirname(testthat::test_path())), ".claude", "scripts", ...))`,
but after Stage 2, `testthat::test_path()` will be relative to `pkg/tests/testthat/`,
changing the `dirname(dirname(...))` traversal. Verify the fallback still resolves
correctly after the move.

**Section summary:** 2 files need investigation/editing, 3 total call sites.
Highest-impact: `tests/testthat/test-roborev-daily-email.R` (path fallback arithmetic
changes when tests move to `pkg/`).

---

## 4. here::here() Calls

`here::here()` walks up from the current working directory and returns the first
directory where **any** criterion in its default chain matches. In this repo,
`_quarto.yml` at the root matches `is_quarto_project` first (confirmed by
`here::dr_here(show_reason = TRUE)` — "This directory contains a file '_quarto.yml'").

The practical effect after moving the package into `pkg/` depends on cwd:

- cwd at or above the repo root → matches `_quarto.yml`, `here()` returns the repo
  root → `here::here("inst/...")` resolves to `repo-root/inst/` (which won't exist
  after the move) → **BREAKS**.
- cwd inside `pkg/` → matches `DESCRIPTION` (`is_r_package`), `here()` returns
  `pkg/` → `here::here("inst/...")` resolves to `pkg/inst/` → **WORKS**.

The breakage is **cwd-dependent**. `tar_make()` run from the repo root breaks;
`tar_make()` run from inside `pkg/` would work.

### 4a. R/ source tree here::here calls

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

### 4b. vignettes/ here::here calls

| File | Line | Content |
|------|------|---------|
| `vignettes/closeread-infrastructure.qmd` | 23 | `setwd(here::here())` |
| `vignettes/closeread-infrastructure.qmd` | 34 | `file.path(here::here(), "inst/extdata/vignettes")` |
| `vignettes/closeread-infrastructure.qmd` | 46–47 | `here::here(".claude", sub)` / `here::here(sub)` |
| `vignettes/telemetry.qmd` | 32 | `setwd(here::here())` |
| `vignettes/telemetry.qmd` | 43 | `file.path(here::here(), "inst/extdata/vignettes")` |
| `vignettes/config-evolution.qmd` | 59 | `here::here(".claude")` |
| `vignettes/config-evolution.qmd` | 61 | `here::here(".claude")` (last-resort fallback) |
| `vignettes/knowledge-evolution.qmd` | 37 | `here::here("inst/extdata/vignettes/vig_kb_stats.rds")` |
| `vignettes/knowledge-evolution.qmd` | 68 | `here::here("knowledge")` |
| `vignettes/articles/scrolly-config-evolution.qmd` | 24 | `setwd(here::here())` |
| `vignettes/articles/scrolly-config-evolution.qmd` | 33 | `file.path(here::here(), "inst/extdata/vignettes")` |
| `vignettes/articles/closeread-config.qmd` | 32 | `setwd(here::here())` |
| `vignettes/articles/closeread-config.qmd` | 41 | `file.path(here::here(), "inst/extdata/vignettes")` |

**Section summary:** 13 distinct files need editing, 24 total line references.
Highest-impact files: `R/tar_plans/plan_vignette_outputs.R` (3 refs),
`vignettes/closeread-infrastructure.qmd` (3 refs).

---

## 5. devtools / usethis / rcmdcheck / pkgload Invocations in CI

No `devtools::`, `usethis::`, `rcmdcheck::`, or `pkgload::` calls were found in any
`.github/workflows/*.yml` or `*.yaml` file.

The CI workflow uses `R CMD INSTALL` directly (see Section 6).

**Section summary:** 0 files need editing. (No impact.)

---

## 6. R CMD check / R CMD build / R CMD INSTALL in CI

| File | Line | Content |
|------|------|---------|
| `.github/workflows/quarto-publish.yaml` | 84 | `run: R CMD INSTALL .` |

This is the critical CI path assumption. `R CMD INSTALL .` installs the package from
the **current working directory** of the CI job. After moving to `pkg/`, this must
become `R CMD INSTALL pkg/`.

**Section summary:** 1 file needs editing, 1 total line reference.
Highest-impact: `.github/workflows/quarto-publish.yaml`.

---

## 7. Config File Locations

| File | Current path | Line count | After Stage 2 | Needs move? |
|------|-------------|-----------|---------------|-------------|
| `_pkgdown.yml` | `/` (repo root) | 6 | Should move to `pkg/_pkgdown.yml` | **Yes** |
| `_quarto.yml` | `/` (repo root) | 44 | Stays at repo root (Quarto website, not package) | No |
| `_targets.R` | `/` (repo root) | 22 | Stays at repo root (pipeline orchestrator) | No |
| `DESCRIPTION` | `/` (repo root) | 46 | Moves to `pkg/DESCRIPTION` | **Yes** |
| `NAMESPACE` | `/` (repo root) | 25 | Moves to `pkg/NAMESPACE` | **Yes** |

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
repo root). The impact is that `R CMD INSTALL .` (Section 6) and
`source("R/tar_plans/...")` in shell steps (Section 1) both assume the repo root
contains the package source.

**Section summary:** 0 explicit working-directory settings found, but the implicit
assumption of repo-root-as-package-root is pervasive.

---

## 9. Roxygen / man References

`man/` exists at the repo root with 25 `.Rd` files. These are generated by
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
| `R/tar_plans/plan_vignette_outputs.R` | 406 | `list.files("R/tar_plans", pattern = "^plan_.*\\.R$", full.names = TRUE)` |
| `R/tar_plans/plan_vignette_outputs.R` | 651 | `list.files("R", pattern = "\\.R$", full.names = TRUE, recursive = TRUE)` |
| `R/tar_plans/plan_vignette_outputs.R` | 655 | `list.files("R/tar_plans", pattern = "^plan_.*\\.R$")` |
| `R/scripts/show_usage_progress.R` | 17 | `source(here::here("R/ccusage.R"))` |

`tar_source("R/tar_plans/")` is the core coupling: `_targets.R` at the repo root
sourcing `R/tar_plans/` by path. After the move to `pkg/`, this must become
`tar_source("pkg/R/tar_plans/")` or the `_targets.R` must itself move into `pkg/`.

The three `list.files("R/...")` calls in `plan_vignette_outputs.R` will silently
return empty results after the move (no error, just missing data in codebase-metrics
and pipeline-summary targets).

**Section summary:** 4 files need editing, 6 total line references.
Highest-impact: `_targets.R` (entry point for entire pipeline).

---

## 11. Per-Section Summary

| # | Section | Files needing edit | Total line refs | Top most-referenced files |
|---|---------|-------------------|-----------------|---------------------------|
| 1 | R/ literals | 7 | 18 | `quarto-publish.yaml` (4), `wiki-sync-check.yaml` (4), `plan_vignette_outputs.R` (4) |
| 2 | tests/ literals | 0 | 0 | — (fixture strings, not path bindings) |
| 3 | system.file() | 2 | 3 | `test-roborev-daily-email.R` (2 call sites), `R/ccusage.R` (1) |
| 4 | here::here() | 13 | 24 | `plan_vignette_outputs.R` (3), `closeread-infrastructure.qmd` (3) |
| 5 | devtools/usethis | 0 | 0 | — |
| 6 | R CMD | 1 | 1 | `quarto-publish.yaml` |
| 7 | Config files | 3 move + 2 stay | 5 files total | `DESCRIPTION`, `NAMESPACE`, `_pkgdown.yml` |
| 8 | Working-dir CI | 0 explicit | 0 | — (implicit repo-root assumption pervasive) |
| 9 | man/ references | 0 | 0 | — |
| 10 | Targets paths | 4 | 6 | `_targets.R`, `plan_vignette_outputs.R` |

---

## 12. Top-Level Summary Table

| Section | Files needing edit | Total line refs | Highest-impact file |
|---|---|---|---|
| R/ literals | 7 | 18 | `.github/workflows/wiki-sync-check.yaml` (4 refs, new since v1) |
| tests/ literals | 0 | 0 | — |
| system.file() | 2 | 3 | `tests/testthat/test-roborev-daily-email.R` |
| here::here() | 13 | 24 | `R/tar_plans/plan_vignette_outputs.R` |
| devtools/usethis | 0 | 0 | — |
| R CMD | 1 | 1 | `.github/workflows/quarto-publish.yaml` |
| Config files | 3 (move) | 5 | `DESCRIPTION` / `NAMESPACE` |
| Working-dir CI | 0 | 0 | — |
| man/ | 0 | 0 | — |
| Targets paths | 4 | 6 | `_targets.R` |
| **TOTAL** | **~22 unique** | **~52** | `.github/workflows/quarto-publish.yaml` + `wiki-sync-check.yaml` |

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

After moving to `pkg/`, `here::here()` resolution becomes **cwd-dependent**. When
`tar_make()` (or any R session) starts at the repo root, `here()` matches `_quarto.yml`
via `is_quarto_project` and returns the repo root — **not** `pkg/`. Every
`here::here("inst/...")` and `here::here("R/...")` will silently resolve to
`repo-root/inst/` and `repo-root/R/` respectively, which won't exist after the move.

**Fix options:**
1. Add a `.here` file inside `pkg/` to make `here::here()` resolve to `pkg/`. This
   would break all the `.claude/`-relative paths in vignettes (e.g., `here::here(".claude")`).
2. Replace all `here::here("inst/...")` with `system.file("...", package = "llm")` —
   works after installation, breaks during development before install.
3. Use `fs::path_package("llm", "extdata")` pattern consistently.
4. Define a package-level constant `PKG_ROOT <- system.file(package = "llm")` and
   build all paths from it.

**Recommendation:** Option 4 is the safest. Requires touching ~13 files.

### 13.2 wiki-sync-check.yaml — New Workflow (HIGH, new since v1)

`wiki-sync-check.yaml` was added after the v1 audit. It has 4 active R/ path
references (lines 15, 22, 47, 133) all pointing to `R/dev/wiki/sync_wiki.R`. After
Stage 2, this file moves to `pkg/R/dev/wiki/sync_wiki.R`. Both push/PR trigger path
filters and the `source()` call in the workflow body need updating.

### 13.3 plan_vignette_outputs.R — list.files("R/...") (HIGH, new since v1)

Three `list.files("R/...")` calls in `plan_vignette_outputs.R` (lines 406, 651, 655)
scan the package source tree to compute pipeline metrics and codebase counts. After
the move, these calls will return empty results (no error, just silent data loss in
`vig_pipeline_summary` and `vig_codebase_metrics` targets).

### 13.4 String-Building R/ Paths in plan_structure.R (HIGH)

`R/tar_plans/plan_structure.R:4` uses `here::here("R/function_analysis.R")` to source
another R file. This will silently resolve to the wrong location after the move.

### 13.5 setwd(here::here()) Pattern (MEDIUM)

Multiple vignettes use:
```r
owd <- setwd(here::here())
on.exit(setwd(owd))
```
The intent is to set cwd to the repo root before loading `inst/extdata/` files. After
the move, `here::here()` still resolves to the repo root (via `_quarto.yml`), so the
`setwd` itself is safe. However, the subsequent `file.path(here::here(), "inst/extdata/vignettes")`
will resolve to `repo-root/inst/` which won't exist — the vignette will fail to load
data unless the path is updated or `inst/` is not moved.

### 13.6 R CMD INSTALL . in CI (HIGH)

`.github/workflows/quarto-publish.yaml:84` runs `R CMD INSTALL .` with the implicit
working directory being the repo root after `actions/checkout`. After Stage 2, this
must change to `R CMD INSTALL pkg/`. Single-line fix but blocks the entire build if
missed.

### 13.7 Push Trigger Path Filters (MEDIUM)

Two path filters will silently stop firing after the move:
- `quarto-publish.yaml:19`: `- 'R/ccusage.R'` → needs `- 'pkg/R/ccusage.R'`
- `wiki-sync-check.yaml:15,22`: `- 'R/dev/wiki/sync_wiki.R'` → needs `- 'pkg/R/dev/wiki/sync_wiki.R'`

### 13.8 test-roborev-daily-email.R Fallback Path Arithmetic (MEDIUM)

The dev-time fallback uses:
```r
normalizePath(
  file.path(dirname(dirname(testthat::test_path())),
            ".claude", "scripts", "send_roborev_email.R"),
  mustWork = FALSE
)
```
After Stage 2, `testthat::test_path()` returns a path under `pkg/tests/testthat/`.
`dirname(dirname(...))` traverses up to `pkg/`, not the repo root. The `.claude/`
directory lives at the repo root, not under `pkg/`. The fallback will fail silently
(returning a non-existent path) and the test expectation will fail.
Fix: update the fallback to traverse one more level up, or use an absolute path anchor.

### 13.9 Targets Store Isolation (LOW)

`_targets.R` uses the default `_targets/` store. If `_targets.R` moves to `pkg/`, the
store would move to `pkg/_targets/`. If it stays at the repo root (recommended), the
store path is stable.

### 13.10 plan_pkgdown.R — Plans for pkgdown Deployment (MEDIUM)

`R/tar_plans/plan_pkgdown.R` contains logic to build the pkgdown site. If `_pkgdown.yml`
moves to `pkg/`, the pkgdown build step must be run from `pkg/`. This plan file likely
needs updating in concert with `_pkgdown.yml`.

---

## 14. Phase B–D Plan (Verbatim from Issue #363)

The following plan is copied verbatim from the issue body. It is reproduced here for
reference during the Phase B dedicated session — do not edit these steps.

---

### Phase B — Dry-run on a fresh worktree

- [ ] Create worktree at `~/worktrees/llm/195-stage2-dryrun/`.
- [ ] `git -C <worktree> mv R pkg/R`, `git -C <worktree> mv tests pkg/tests`, `git -C <worktree> mv man pkg/man`, `git -C <worktree> mv inst pkg/inst`, `git -C <worktree> mv DESCRIPTION pkg/DESCRIPTION`, `git -C <worktree> mv NAMESPACE pkg/NAMESPACE`.
- [ ] Update _quarto.yml `renderRoot:`/`projectDir:` if needed.
- [ ] Update _targets.R paths.
- [ ] Update _pkgdown.yml.
- [ ] Update every workflow's `working-directory: pkg` (or `R CMD check pkg/`).
- [ ] Run `(cd pkg && Rscript -e 'devtools::check()')` — must pass clean.
- [ ] Run `Rscript -e 'targets::tar_make()'` — must build all vignette targets.
- [ ] Run `quarto render` — must produce docs/ with all articles.
- [ ] Run `quarto render --to pkgdown` — must produce reference/.
- [ ] Smoke-test 3 vignettes manually in the browser.

### Phase C — Single PR

- [ ] Commit all changes as `refactor(#195): move R package into pkg/ subfolder (Stage 2)`.
- [ ] PR body must enumerate every file class moved + every config touched.
- [ ] Open PR with `[no auto-merge]` tag — requires manual review.
- [ ] Critic agent reviews the diff against the audit from Phase A.
- [ ] Orchestrator runs a parallel smoke-test of vignettes + pkgdown + tar_make.
- [ ] Merge only after critic + manual smoke pass.

### Phase D — Post-merge verification

- [ ] Nightly vignette-validation workflow runs cleanly for 7 days.
- [ ] pkgdown deploys produce identical reference structure.
- [ ] No broken intra-repo links surfaced by `check_links` in QA gates.
- [ ] Close #195.

---

## 15. Recommended Stage 2 Work Order

Based on this audit, the following order minimises risk of cascading failures:

### Phase B-1: Investigation (Before Any Move)
1. **Clarify vignette co-location decision**: do `vignettes/` and `_quarto.yml` move
   into `pkg/` or stay at the repo root? This decision changes the scope significantly.
2. **Fix `test-roborev-daily-email.R`** fallback path arithmetic before the move —
   the `dirname(dirname(testthat::test_path()))` traversal breaks when tests move to `pkg/`.
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
11. Update all `here::here("inst/...")` calls in `R/tar_plans/*.R`.
12. Update all `list.files("R/...")` calls in `plan_vignette_outputs.R`.

### Phase B-4: Config Files (Medium-Coupling)
13. Move `_pkgdown.yml` to `pkg/_pkgdown.yml`.
14. Update `plan_pkgdown.R` to build from `pkg/`.

### Phase B-5: CI Workflows (Lowest Risk Last — Single Verified Change)
15. Update `.github/workflows/quarto-publish.yaml`:
    - Line 19: push trigger path filter `R/ccusage.R` → `pkg/R/ccusage.R`
    - Line 84: `R CMD INSTALL .` → `R CMD INSTALL pkg/`
    - Line 100: `source("R/tar_plans/plan_qa_gates.R")` → `source("pkg/R/tar_plans/plan_qa_gates.R")`
16. Update `.github/workflows/wiki-sync-check.yaml` (new since v1 audit):
    - Lines 15, 22: path filter `R/dev/wiki/sync_wiki.R` → `pkg/R/dev/wiki/sync_wiki.R`
    - Line 47: `source("R/dev/wiki/sync_wiki.R", ...)` → `source("pkg/R/dev/wiki/sync_wiki.R", ...)`
    - Line 133: error message text

### Phase B-6: Vignette Fixes (Last — Render Verification Required)
17. Update `vignettes/*.qmd` `here::here("inst/...")` references if vignettes remain
    outside `pkg/`.
18. Run `quarto render` to verify all vignettes load correctly post-move.

**Highest-risk-last rationale:** the CI workflow changes (Phase B-5) are single files,
highly reviewable, and fail fast. Vignette fixes (Phase B-6) require a render to verify,
making them slower to iterate on — do them last when the package itself is confirmed to
install correctly.
