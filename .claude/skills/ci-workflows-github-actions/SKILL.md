---
name: ci-workflows-github-actions
description: Use when setting up or debugging GitHub Actions workflows for R packages, configuring Nix-based CI, r-universe testing, WASM compilation, code coverage, or pkgctx API documentation. Triggers: CI, GitHub Actions, workflows, r-universe, WASM, coverage, deployment.
---
# CI Workflows with GitHub Actions

## Description

GitHub Actions workflows for R package development: Nix-based builds, r-universe testing, WASM compilation, code coverage, pkgctx API documentation, and deployment.

## Purpose

Use this skill when:
- Setting up CI/CD for R packages
- Testing against r-universe build process
- Building WebAssembly (WASM) versions of packages
- Configuring code coverage reporting
- Using Cachix for Nix store caching
- Implementing reusable workflow patterns
- Setting up pkgctx API documentation workflows

## Workflow Catalog

Nine workflows are available. Full YAML templates are in the references directory.

### Core Build & Test Workflows

**1. R-CMD-check (Nix-based)** -- `.github/workflows/r-cmd-check.yaml`
Reproducible R CMD check using Nix with two-tier Cachix caching. Uses `default-ci.nix` and `skipPush: true` on project cache.

**2. R-Universe Test** -- `.github/workflows/r-universe-test.yml`
Tests exact r-universe.dev build process. Builds on Linux, Windows, MacOS with CRAN-equivalent R versions. Uses reusable workflow from `r-universe-org/workflows`.
Ref: [rOpenSci blog](https://ropensci.org/blog/2026/01/03/r-universe-workflows/)

**3. Code Coverage (Non-Nix)** -- `.github/workflows/coverage.yaml`
Uses Native R (not Nix -- `covr` fails in Nix with "error reading from connection"). Generates `coverage.rds`, commits to repo for telemetry vignette consumption.

**4. WASM Build** -- `.github/workflows/build-rwasm.yml`
Builds WebAssembly binaries for Shinylive browser-based Shiny apps via `r-wasm/actions/build-rwasm@v2`.

**5. Deploy to GitHub Pages (Hybrid)** -- `.github/workflows/deploy-pages.yaml`
Native R for pkgdown (bslib incompatible with Nix). Uses `actions/deploy-pages@v4`.

**6. Nix Environment Builder** -- `.github/workflows/nix-builder.yaml`
Pre-builds Nix environment on push to `default.nix`/`default-ci.nix`/`package.nix` and pushes to Cachix.

See [workflow-templates.md](references/workflow-templates.md) for all YAML templates.

### Package Context Workflows (pkgctx)

**7. Auto-Update Package Context** -- `.github/workflows/update-pkg-context.yaml`
Regenerates `package.ctx.yaml` on push to main when `R/`, `NAMESPACE`, or `DESCRIPTION` change.

**8. API Drift Detection** -- `.github/workflows/api-drift-check.yaml`
Warns (does not fail) on PRs when function signatures change vs committed `package.ctx.yaml`.

**9. Weekly Dependency Context Update** -- `.github/workflows/update-dep-context.yaml`
Scheduled Sunday 3am UTC. Regenerates `.claude/context/*.ctx.yaml` for key dependencies.

See [pkgctx-workflows.md](references/pkgctx-workflows.md) for full YAML templates. See `llm-package-context` skill for pkgctx usage details.

## Decision Matrix

| Need | Workflow | Environment |
|------|----------|-------------|
| Standard R CMD check | r-cmd-check.yaml | Nix |
| r-universe compatibility | r-universe-test.yml | r-universe |
| Code coverage | coverage.yaml | Native R |
| WASM/Shinylive | build-rwasm.yml | r-wasm |
| Documentation site | deploy-pages.yaml | Native R (hybrid) |
| Pre-build Nix cache | nix-builder.yaml | Nix |
| LLM package context | update-pkg-context.yaml | Nix (pkgctx) |
| API drift detection | api-drift-check.yaml | Nix (pkgctx) |
| Dependency context | update-dep-context.yaml | Nix (pkgctx) |

## Cachix Integration

### Two-Tier Strategy

Always configure public cache first, project cache second:
1. `rstats-on-nix` -- pre-built R packages (public, read-only)
2. `johngavin` -- project-specific custom builds (auth required)

### Push Rules (Step 5 of 9-Step Workflow)

**Push to johngavin:** Custom GitHub packages not in rstats-on-nix, patched packages, project-specific derivations.

**Do NOT push:** Standard CRAN packages (already in rstats-on-nix), dev packages via `load_all()`, shells with only standard packages.

```bash
# Push only custom packages
nix-store -qR $(nix-build default-ci.nix) | cachix push johngavin
# Or use the project helper
./push_to_cachix.sh
```

See [nix-ci-patterns.md](references/nix-ci-patterns.md) for full Cachix configuration, reusable workflow patterns, and detailed examples.

## Trigger Patterns

| Pattern | When |
|---------|------|
| `push: branches: [main]` | Merge to main only |
| `push` + `pull_request` on `[main, master]` | PR and merge |
| `push: paths: ['R/**', 'tests/**']` | Specific file changes |
| `workflow_dispatch:` | Manual trigger |
| `schedule: cron: '0 2 * * *'` | Scheduled (daily 2am UTC) |

See [workflow-templates.md](references/workflow-templates.md) for YAML examples of each pattern.

## Required Secrets

| Secret | Purpose | Where to get |
|--------|---------|--------------|
| `GITHUB_TOKEN` | Auto-provided | GitHub |
| `CACHIX_AUTH_TOKEN` | Push to Cachix | cachix.org |
| `CODECOV_TOKEN` | Coverage upload | codecov.io |

## Best Practices

1. **Use path filters** -- Don't run CI on unrelated changes
2. **Two-tier Cachix** -- Public cache first, project cache second
3. **Skip CI commits** -- Use `[skip ci]` for automated commits
4. **Artifact upload on failure** -- Debug failed checks easily
5. **Native R for web tools** -- bslib/pkgdown don't work in Nix
6. **Test r-universe locally** -- Catch issues before deployment

## Related Skills

- `nix-rix-r-environment` -- Core Nix/rix setup, `available_dates()`
- `pkgdown-deployment` -- Hybrid deployment details
- `verification-before-completion` -- CI verification patterns
- `r-package-workflow` -- 9-step workflow with CI integration
- `llm-package-context` -- pkgctx usage, API drift detection

## Resources

- [r-universe workflows](https://github.com/r-universe-org/workflows)
- [r-lib/actions](https://github.com/r-lib/actions)
- [r-wasm/actions](https://github.com/r-wasm/actions)
- [Cachix documentation](https://docs.cachix.org/)
- [GitHub Actions docs](https://docs.github.com/en/actions)
- [pkgctx](https://github.com/b-rodrigues/pkgctx) -- LLM package context generator
