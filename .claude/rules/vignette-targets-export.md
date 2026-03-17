---
paths:
  - "vignettes/**"
  - "inst/extdata/vignettes/**"
  - ".github/workflows/**"
  - "R/tar_plans/**"
---
# Vignette CI Pattern: Pre-Computed RDS Only

## Core Principle

**CI NEVER runs `tar_make()` for data-heavy pipelines.** Vignettes MUST precompute EVERYTHING locally.

## Why CI Cannot Run tar_make()

1. **Data downloads**: Pipelines download external data (100+ CSV files, APIs, etc.)
2. **Timeout limits**: CI has 40-minute timeout; full pipelines exceed this
3. **External dependencies**: APIs may rate-limit, be unavailable, or change
4. **Reproducibility**: CI should validate pre-computed outputs, not rebuild from scratch
5. **Cost**: Downloading/processing data on every CI run wastes resources

## Correct Pattern: Pre-Computed RDS

### Local Workflow (Developer)

```r
# 1. Build pipeline locally (downloads data, fits models, etc.)
targets::tar_make()

# 2. Export vignette targets to RDS
out_dir <- here::here("inst", "extdata", "vignettes")
if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)

vignette_targets <- grep("^vig_", targets::tar_manifest()$name, value = TRUE)
for (name in vignette_targets) {
  obj <- targets::tar_read_raw(name)
  saveRDS(obj, file.path(out_dir, paste0(name, ".rds")))
}

# 3. Commit RDS files
gert::git_add("inst/extdata/vignettes/*.rds")
gert::git_commit("chore: export pre-computed vignette targets")
gert::git_push()
```

### CI Workflow (GitHub Actions)

**pkgdown.yml should NOT contain any tar_make() step:**

```yaml
# CORRECT: No tar_make(), just build site using pre-computed RDS
- name: Build pkgdown site
  run: |
    nix-shell default.nix -A shell --run "Rscript -e '
      devtools::document()
      pkgdown::build_site(preview = FALSE)
    '"
```

### Vignette Chunk Pattern (MANDATORY)

```qmd
```{r chunk-name, fig.cap = "Description..."}
#| echo: false
#| results: asis
show_target("vig_target_name")
```
```

**Key rules:**
- `#| echo: false` — NEVER show `show_target(...)` in the code fold; instead,
  `show_target()` renders a `<details>Generating code</details>` block with the
  actual R code that computed the target
- `#| results: asis` — required for markdown text and `<details>` HTML blocks
- Use `show_target()` for ALL display chunks — NEVER bare `safe_tar_read()`
- `safe_tar_read()` and `show_target()` are defined in `inst/vignette_utils.R`
  — all vignettes `source()` this file, NO inline definitions

### Code Provenance (code_vig_* targets)

Every `vig_*` target has a `code_vig_*` counterpart containing the R code:
- 20 pipeline targets: `code_vig_*` in `plan_vignette_outputs.R` (extract function body)
- 78 RDS-only: exported from `tar_manifest()$command` (target definition body)
- `show_target()` reads `code_vig_*` → displays in collapsible `<details>` block

### RDS Export Rules

```r
# DT targets → save as data.frame (NOT DT widget — contains Nix store paths)
df <- dt_widget$x$data  # extract data
attr(df, "dt_caption") <- dt_widget$x$caption  # preserve caption
saveRDS(df, path, compress = "xz")

# ggplot targets → save as ggplotGrob() (strips S7 env overhead)
saveRDS(ggplot2::ggplotGrob(p), path, compress = "xz")

# safe_tar_read() re-wraps at render time using CI's own DT/grid installation
```

## When tar_make() in CI IS Appropriate

Only for **lightweight pipelines** where:
- No external data downloads (data already in repo)
- No long-running computations (< 5 minutes total)
- No external API dependencies
- Example: irishbuoys uses `targets-runs` branch pattern for incremental builds

For most R packages with data pipelines: **use pre-computed RDS**.

## Checklist Before Merging

- [ ] All `vig_*` targets built locally: `tar_make(names = starts_with("vig_"))`
- [ ] RDS exported via `export_dt_as_df.R` (strips DT widgets to data.frames)
- [ ] `rds_nix_path_check` target passes (0 Nix path violations)
- [ ] All `code_vig_*` RDS files exported (from pipeline targets + manifest)
- [ ] All vignette chunks use `show_target()` with `#| echo: false`
- [ ] RDS files committed: `git status` shows no unstaged RDS
- [ ] CI deploy succeeds: `gh run list --workflow 04-website.yaml`
- [ ] **NEVER trust local pkgdown builds** — `docs/` is gitignored, CI builds on Ubuntu

## Common Violations

1. **Saving DT widgets to RDS** — Contains Nix store paths, CI fails with `path for html_dependency not found`
2. **Using `safe_tar_read()` instead of `show_target()`** — Shows `safe_tar_read(...)` in code fold instead of generating R code
3. **Missing `#| echo: false`** — Quarto shows chunk source code instead of generating code
4. **Not checking CI after push** — Local builds pass but CI fails silently
5. **Forgetting to export `code_vig_*` RDS** — Code provenance missing in CI builds

## Related Files

- `R/tar_plans/plan_vignette_outputs.R` - defines `vig_*` targets
- `inst/extdata/vignettes/*.rds` - pre-computed outputs
- `vignettes/*.qmd` - consume via `safe_tar_read()`
- `.github/workflows/pkgdown.yml` - CI workflow (NO tar_make())
