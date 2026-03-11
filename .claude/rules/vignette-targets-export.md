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

### Vignette Code (safe_tar_read fallback)

```r
safe_tar_read <- function(name) {
  # Try targets store first (for local development)
  result <- tryCatch(targets::tar_read_raw(name), error = function(e) NULL)

  # Fallback to pre-computed RDS (for CI/pkgdown builds)
  if (is.null(result)) {
    # Try installed package location
    rds_path <- system.file(
      file.path("extdata", "vignettes", paste0(name, ".rds")),
      package = "pkgname"
    )
    # Fallback to source inst/ directory (pkgdown builds from source)
    if (!nzchar(rds_path) || !file.exists(rds_path)) {
      rds_path <- here::here("inst", "extdata", "vignettes", paste0(name, ".rds"))
    }
    if (file.exists(rds_path)) {
      result <- readRDS(rds_path)
    }
  }

  # Return error indicator if still missing
  if (is.null(result)) {
    htmltools::div(
      style = "background:#dc3545;color:white;padding:1em;border-radius:4px;",
      paste0("[MISSING EVIDENCE] Target `", name, "` not found in _targets/ or RDS fallback.")
    )
  } else {
    result
  }
}
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
- [ ] All RDS files exported: `list.files("inst/extdata/vignettes", "\\.rds$")`
- [ ] RDS files committed: `git status` shows no unstaged RDS
- [ ] pkgdown.yml has NO tar_make() step (unless lightweight pipeline)
- [ ] Vignettes use `safe_tar_read()` with RDS fallback
- [ ] CI builds pass without timeout

## Common Violations

1. **Adding tar_make() to CI** - Causes 40-minute timeout for data-heavy pipelines
2. **Forgetting to export RDS** - Vignettes show [MISSING EVIDENCE] on live site
3. **Stale RDS files** - Target code changes but RDS not re-exported
4. **Missing here::here() fallback** - system.file() doesn't work for pkgdown source builds

## Related Files

- `R/tar_plans/plan_vignette_outputs.R` - defines `vig_*` targets
- `inst/extdata/vignettes/*.rds` - pre-computed outputs
- `vignettes/*.qmd` - consume via `safe_tar_read()`
- `.github/workflows/pkgdown.yml` - CI workflow (NO tar_make())
