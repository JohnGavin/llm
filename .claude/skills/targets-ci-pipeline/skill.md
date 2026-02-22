# Targets CI Pipeline

## Description

Comprehensive guide for running `targets` pipelines in GitHub Actions CI,
covering the `targets-runs` branch pattern, `tar_validate()` integration,
vignette rendering, and first-run bootstrapping.

## Purpose

Use this skill when:
- Setting up CI for an R package that uses `targets`
- Choosing between `targets-runs` branch vs LFS-on-main vs validate-only approaches
- Adding `tar_validate()` to R-CMD-check workflows
- Rendering vignettes that depend on `tar_load()` in CI
- Bootstrapping the `targets-runs` orphan branch for the first time
- Troubleshooting pipeline failures in CI

## Decision Tree: Which Approach?

```
Does your project use targets?
├── No → Skip this skill
└── Yes → Does your pipeline produce large binary artifacts (> 50 MB)?
    ├── Yes → Use targets-runs branch pattern
    └── No → Do vignettes call tar_load()?
        ├── Yes → Use targets-runs branch pattern (CI needs _targets/)
        └── No → tar_validate() in R-CMD-check is sufficient
```

### Approach Comparison

| Aspect | `targets-runs` branch | `_targets/` on main (LFS) | `tar_validate()` only |
|--------|----------------------|---------------------------|----------------------|
| Main branch cleanliness | Clean | Polluted with binaries | Clean |
| Incremental CI builds | Yes | Yes | N/A |
| Vignette rendering in CI | Yes | Yes | No |
| LFS dependency | None | Required | None |
| Workflow complexity | Higher | Lower | Minimal |
| Repo size | main stays small | Grows with each run | No growth |

## Pattern 1: `tar_validate()` in R-CMD-check (Lightweight)

Add to any project with `_targets.R`. Runs on every push/PR. Fast (< 5s).

```yaml
# In R-CMD-check.yml, after the R CMD check step:
      - name: Validate targets pipeline
        run: |
          nix-shell default.nix -A shell --run "Rscript -e '
            targets::tar_validate()
            cat(\"Pipeline valid:\", length(targets::tar_manifest()\$name), \"targets\\n\")
          '"
```

**What it catches:**
- Syntax errors in `_targets.R` and plan files
- Missing function references
- Circular dependencies
- Invalid target specifications

**What it does NOT catch:**
- Runtime errors (data unavailable, API down)
- Package loading failures
- Slow/hanging targets

## Pattern 2: Full Pipeline with `targets-runs` Branch (Nix)

Complete workflow for incremental pipeline execution with state caching.

### Workflow Template

```yaml
name: Run Pipeline

on:
  schedule:
    - cron: '0 2 * * 0'  # Weekly (adjust as needed)
  push:
    branches: [main]
    paths:
      - 'R/**'
      - '_targets.R'
      - 'DESCRIPTION'
  workflow_dispatch:

jobs:
  targets:
    runs-on: ubuntu-latest
    timeout-minutes: 60
    env:
      GITHUB_PAT: ${{ secrets.GITHUB_TOKEN }}

    steps:
      # ── Checkout & Environment ──────────────────────────────

      - uses: actions/checkout@v6
        with:
          fetch-depth: 0  # Full history for targets-runs branch

      - name: Install Nix
        uses: DeterminateSystems/nix-installer-action@main
        with:
          logger: pretty
          log-directives: nix_installer=trace
          backtrace: full

      - name: Setup magic Nix cache
        uses: DeterminateSystems/magic-nix-cache-action@main

      - name: Setup Cachix (rstats-on-nix + project)
        uses: cachix/cachix-action@v15
        with:
          name: rstats-on-nix
          extraPullNames: johngavin  # Replace with your cache

      - name: Build development environment
        run: nix-build default.nix -A shell --no-out-link

      # ── Restore Pipeline State ──────────────────────────────

      - name: Check if targets-runs branch exists
        id: runs-exist
        run: git ls-remote --exit-code --heads origin targets-runs
        continue-on-error: true

      - name: Checkout previous pipeline state
        if: steps.runs-exist.outcome == 'success'
        uses: actions/checkout@v6
        with:
          ref: targets-runs
          fetch-depth: 1
          path: .targets-runs

      - name: Restore _targets/ from previous run
        if: steps.runs-exist.outcome == 'success'
        run: |
          if [ -f ".targets-runs/.targets-files" ]; then
            nix-shell default.nix -A shell --run "Rscript -e '
              files <- scan(\".targets-runs/.targets-files\", what = character())
              restored <- 0L
              for (dest in files) {
                source <- file.path(\".targets-runs\", dest)
                if (!file.exists(dirname(dest))) dir.create(dirname(dest), recursive = TRUE)
                if (file.exists(source)) { file.rename(source, dest); restored <- restored + 1L }
              }
              cat(\"Restored\", restored, \"pipeline files from targets-runs\\n\")
            '"
          else
            echo "No .targets-files manifest — running from scratch"
          fi

      # ── Run Pipeline ────────────────────────────────────────

      - name: Validate pipeline definition
        run: |
          nix-shell default.nix -A shell --run "Rscript -e '
            targets::tar_validate()
            cat(\"Pipeline valid:\", length(targets::tar_manifest()\$name), \"targets\\n\")
          '"

      - name: Run targets pipeline
        run: |
          nix-shell default.nix -A shell --run "Rscript -e '
            targets::tar_make()
          '" || echo "Pipeline completed with warnings"

      # ── (Optional) Render Vignettes ─────────────────────────
      # Uncomment if vignettes use tar_load()

      # - name: Render vignettes
      #   run: |
      #     nix-shell default.nix -A shell --run "
      #       cd vignettes && quarto render my_vignette.qmd --output-dir ../docs/articles/
      #     " || echo "Vignette render failed"

      # ── Commit Outputs to main ──────────────────────────────

      - name: Commit rendered outputs to main
        run: |
          git config --local user.email "action@github.com"
          git config --local user.name "GitHub Action"
          git add inst/extdata/*.rds || true
          git add docs/ || true
          git diff --staged --quiet || git commit -m "Pipeline update: $(date +'%Y-%m-%d')"
          git push || true

      # ── Save Pipeline State to targets-runs ─────────────────

      - name: Identify pipeline output files
        run: git ls-files -mo --exclude='*.duckdb' --exclude='.targets-runs' > .targets-files

      - name: Create targets-runs branch if needed
        if: steps.runs-exist.outcome != 'success'
        run: git checkout --orphan targets-runs

      - name: Switch to targets-runs branch
        if: steps.runs-exist.outcome == 'success'
        run: |
          rm -r .git
          mv .targets-runs/.git .
          rm -rf .targets-runs

      - name: Commit pipeline state to targets-runs
        run: |
          git config --local user.name "GitHub Actions"
          git config --local user.email "actions@github.com"
          rm -rf .gitignore .github/workflows
          git add --all -- ':!*.duckdb'
          for file in $(cat .targets-files); do
            git add --force "$file" 2>/dev/null || true
          done
          git commit -am "Pipeline state: $(date +'%Y-%m-%d')" || echo "No changes"
          git push origin targets-runs || echo "Failed to push targets-runs"

      # ── Artifacts ───────────────────────────────────────────

      - name: Post failure artifact
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: pipeline-failure
          path: .
```

## First-Run Bootstrapping

The `targets-runs` branch is created automatically on first workflow run
(via `git checkout --orphan targets-runs`). No manual setup needed.

**However**, if you want to pre-seed it locally:

```bash
# Create orphan branch
git checkout --orphan targets-runs
git rm -rf .

# Run pipeline locally
Rscript -e 'targets::tar_make()'

# Track output files
git ls-files -mo --exclude='*.duckdb' > .targets-files
git add --all -- ':!*.duckdb'
git commit -m "Initial pipeline state"
git push origin targets-runs

# Return to main
git checkout main
```

## Vignette Rendering Integration

When vignettes use `tar_load()`, they need `_targets/` present:

1. **Restore** `_targets/` from `targets-runs` branch (done in workflow)
2. **Run** `tar_make()` to update targets
3. **Render** vignettes in the same job (tar_load works because _targets/ exists)
4. **Commit** rendered outputs to main
5. **Save** updated `_targets/` back to `targets-runs`

**Key insight:** Rendering happens AFTER pipeline run, BEFORE state save.

## Troubleshooting

### Pipeline fails with "could not find function"

**Cause:** Package not loaded. In Nix workflows, use:
```yaml
run: nix-shell default.nix -A shell --run "Rscript -e 'devtools::load_all(); targets::tar_make()'"
```

### targets-runs branch grows too large

**Cause:** Large objects in `_targets/objects/`.
**Fix:** Add exclusions to the file manifest:
```yaml
run: git ls-files -mo --exclude='*.duckdb' --exclude='*.parquet' > .targets-files
```

### First run takes very long

**Expected.** Subsequent runs are incremental (only rebuild changed targets).
Set a generous `timeout-minutes` for first run (60-120).

### Vignette render fails with "target X not found"

**Cause:** Target not built or `_targets/` not restored.
**Fix:** Ensure `tar_make()` runs BEFORE vignette rendering in the workflow.

### "permission denied" pushing to targets-runs

**Cause:** Missing write permissions.
**Fix:** Add to workflow:
```yaml
permissions:
  contents: write
```

## Mandatory CI Features (Checklist)

Every targets CI workflow MUST include:

- [ ] `GITHUB_PAT: ${{ secrets.GITHUB_TOKEN }}` at job level
- [ ] `actions/checkout@v6`
- [ ] Verbose Nix installer (`logger: pretty`, `log-directives: nix_installer=trace`, `backtrace: full`)
- [ ] `tar_validate()` before `tar_make()` (catches definition errors fast)
- [ ] Failure artifact upload
- [ ] `timeout-minutes` set appropriately

## Related Skills

- `ci-workflows-github-actions` - General CI workflow patterns
- `targets-vignettes` - Pre-computed vignette pattern
- `r-package-workflow` - 9-step development workflow
- `nix-rix-r-environment` - Nix environment setup

## References

- [b-rodrigues/nix_targets_pipeline](https://github.com/b-rodrigues/nix_targets_pipeline)
- [ropensci/targets CI template](https://github.com/ropensci/targets/blob/main/.github/workflows/targets.yaml)
- [targets manual: CI/CD](https://books.ropensci.org/targets/ci.html)
