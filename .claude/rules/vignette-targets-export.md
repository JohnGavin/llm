# Vignette Targets CI Rule

## Description

When adding or modifying targets that are used in vignettes (targets prefixed with `vig_`), ensure the CI workflow runs `tar_make()` before building the pkgdown site.

## Standard Pattern (RECOMMENDED)

CI should run `tar_make()` to build vignette targets. This is the pattern used in:
- **etfs**: `targets::tar_make()` before `pkgdown::build_site()` (simple)
- **irishbuoys**: Full pipeline with `targets-runs` branch for state persistence (complex)

### Minimal CI Setup

Add this step BEFORE `pkgdown::build_site()` in `.github/workflows/pkgdown.yml`:

```yaml
- name: Run targets pipeline
  run: |
    nix-shell default.nix -A shell --run "Rscript -e '
      # Build vignette targets (vig_*) required for pkgdown site
      targets::tar_make(names = tidyselect::starts_with(\"vig_\"))
    '"
```

## Fallback Pattern (LEGACY)

For projects where `tar_make()` in CI is not feasible (e.g., external API dependencies, long-running computations), use pre-computed RDS files:

1. Export targets to `inst/extdata/vignettes/*.rds` locally
2. Commit RDS files to the repo
3. Use `safe_tar_read()` pattern with RDS fallback in vignettes

**This is NOT recommended** - prefer running `tar_make()` in CI.

## Why tar_make() in CI is Better

- **Single source of truth**: Targets code defines outputs, not duplicated RDS files
- **Always fresh**: No stale RDS files when target code changes
- **Less maintenance**: No manual export/commit workflow
- **Consistent with other projects**: irishbuoys, etfs use this pattern

## Common Violations

1. **pkgdown.yml missing tar_make()** - Workflow only runs `pkgdown::build_site()` without first building targets
2. **Relying on manual RDS export** - Developer must remember to export after changes
3. **Stale RDS files** - Target code changes but RDS not re-exported

## Integration with Workflow

Before merging PRs that modify `vig_*` targets:
- Verify CI runs `tar_make()` before `pkgdown::build_site()`
- Check that targets build successfully in CI logs

## Related

- `R/tar_plans/plan_vignette_outputs.R` - defines `vig_*` targets
- `vignettes/*.qmd` - consume targets via `tar_load()` / `tar_read()`
- `.github/workflows/pkgdown.yml` - CI workflow that builds targets
