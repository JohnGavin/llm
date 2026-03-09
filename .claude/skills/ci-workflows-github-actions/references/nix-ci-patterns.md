# Nix CI Patterns and Cachix Integration

Detailed Nix-specific CI patterns including Cachix caching strategy, local push rules, and reusable workflow patterns.

## Two-Tier Caching Strategy

```yaml
# 1. Public cache FIRST (contains pre-built R packages)
- uses: cachix/cachix-action@v15
  with:
    name: rstats-on-nix

# 2. Project cache SECOND (your custom builds)
- uses: cachix/cachix-action@v15
  with:
    name: johngavin
    authToken: '${{ secrets.CACHIX_AUTH_TOKEN }}'
```

## Local Push to Cachix (Step 5 of 9-Step Workflow)

**IMPORTANT: Only push PROJECT-SPECIFIC packages to johngavin cache!**

- Standard R packages (dplyr, ggplot2, targets, etc.) are ALL in `rstats-on-nix`
- Only push custom packages NOT available in rstats-on-nix
- For development packages loaded via `load_all()`, there's nothing to push
- Pushing standard R packages wastes limited Cachix quota

```bash
# Push ONLY if you have custom packages in default-ci.nix/package.nix
# that are NOT available from rstats-on-nix
nix-store -qR $(nix-build default-ci.nix) | cachix push johngavin

# Or use helper script (should be project-aware)
./push_to_cachix.sh
```

**When to push to johngavin:**
- Custom R packages built from GitHub (not in rstats-on-nix)
- Modified/patched versions of packages
- Project-specific Nix derivations

**When NOT to push:**
- Standard CRAN packages (already in rstats-on-nix)
- Development packages loaded via `load_all()`
- Shell environments with only standard packages

## Reusable Workflow Patterns

### Calling External Reusable Workflows

```yaml
jobs:
  build:
    uses: r-universe-org/workflows/.github/workflows/build.yml@v3
    with:
      universe: ${{ github.repository_owner }}
```

### Creating Your Own Reusable Workflow

```yaml
# .github/workflows/reusable-check.yml
name: Reusable R Check

on:
  workflow_call:
    inputs:
      r-version:
        description: 'R version to use'
        default: 'release'
        type: string

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: r-lib/actions/setup-r@v2
        with:
          r-version: ${{ inputs.r-version }}
      # ... rest of workflow
```
