# Package Context (pkgctx) CI Workflows

Workflows for generating LLM-optimized API documentation and detecting API drift. See `llm-package-context` skill for full details on pkgctx usage.

## Auto-Update Package Context

**File:** `.github/workflows/update-pkg-context.yaml`

```yaml
name: Update Package Context

on:
  push:
    branches: [main]
    paths:
      - 'DESCRIPTION'
      - 'R/**'
      - 'NAMESPACE'
  workflow_dispatch:

permissions:
  contents: write

jobs:
  update-context:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: DeterminateSystems/nix-installer-action@main

      - uses: DeterminateSystems/magic-nix-cache-action@main

      - name: Generate package context
        run: |
          nix run github:b-rodrigues/pkgctx -- r . --compact > package.ctx.yaml

      - name: Commit updated context
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add package.ctx.yaml
          git diff --staged --quiet || git commit -m "Update package API context [skip ci]"
          git push
```

**Purpose:** Auto-generate structured API documentation for LLMs after code changes.

## API Drift Detection (Warning Only)

**File:** `.github/workflows/api-drift-check.yaml`

```yaml
name: Check API Drift

on:
  pull_request:
    paths:
      - 'R/**'
      - 'NAMESPACE'
      - 'DESCRIPTION'

jobs:
  check-drift:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: DeterminateSystems/nix-installer-action@main

      - uses: DeterminateSystems/magic-nix-cache-action@main

      - name: Generate current context
        run: |
          nix run github:b-rodrigues/pkgctx -- r . --compact > current.ctx.yaml

      - name: Check for API drift
        run: |
          if [ -f package.ctx.yaml ]; then
            if ! diff -q package.ctx.yaml current.ctx.yaml > /dev/null 2>&1; then
              echo "::warning::API has changed! Review changes below:"
              diff package.ctx.yaml current.ctx.yaml || true
            else
              echo "No API drift detected."
            fi
          else
            echo "::notice::No existing package.ctx.yaml - will be created on merge."
          fi
```

**Purpose:** Warn (not fail) when function signatures change in PRs.

## Weekly Dependency Context Update

**File:** `.github/workflows/update-dep-context.yaml`

```yaml
name: Update Dependency Context

on:
  schedule:
    - cron: '0 3 * * 0'  # Weekly on Sunday at 3am UTC
  workflow_dispatch:

permissions:
  contents: write

jobs:
  update-deps:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: DeterminateSystems/nix-installer-action@main

      - name: Generate context for dependencies
        run: |
          mkdir -p .claude/context
          # Adjust package list per project
          for pkg in targets dplyr tidyr purrr gert gh usethis devtools; do
            echo "Generating context for $pkg..."
            nix run github:b-rodrigues/pkgctx -- r "$pkg" --compact \
              > ".claude/context/${pkg}.ctx.yaml" || true
          done

      - name: Commit updated context
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add .claude/context/
          git diff --staged --quiet || git commit -m "Weekly: update dependency API context [skip ci]"
          git push
```

**Purpose:** Keep dependency API context fresh for LLM use.
