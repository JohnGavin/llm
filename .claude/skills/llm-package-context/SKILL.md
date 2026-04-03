---
name: llm-package-context
description: Use when generating compact API specifications from R/Python packages for LLM consumption, using pkgctx tool, or managing central context caches. Triggers: pkgctx, package context, API spec, LLM context, token reduction, function signatures.
---
# LLM Package Context with pkgctx

## Description

This skill covers generating structured, compact API specifications from R and Python packages for use in LLMs. The `pkgctx` tool minimizes token usage (~67% reduction) while maximizing useful context about function signatures, arguments, and documentation.

## Purpose

Use this skill when:
- Providing Claude/GPT with package API context
- Documenting project dependencies for LLM consumption
- Detecting API drift/breaking changes in CI
- Creating reproducible package documentation
- Reducing token usage for package context in prompts

## Key Concepts

### What pkgctx Does

`pkgctx` extracts from packages:
- Function signatures and exported APIs
- Argument names and descriptions
- Brief purpose summaries
- Class definitions (Python)

**Output format:** YAML or JSON with `kind` field discriminators:
- `context_header` - LLM instructions
- `package` - Package metadata
- `function` - Function documentation
- `class` - Class definitions (Python)

### Token Efficiency

| Mode | Reduction | Use Case |
|------|-----------|----------|
| Default | Baseline | Full documentation |
| `--compact` | ~67% | Most LLM contexts |
| `--compact --hoist-common-args` | ~75% | Packages with shared args |

## Running pkgctx (No Installation)

**Requires only Nix installed.** Run directly from GitHub:

```bash
# Basic syntax
nix run github:b-rodrigues/pkgctx -- <language> <source> [options] > output.ctx.yaml
```

### R Package Sources

```bash
# CRAN package
nix run github:b-rodrigues/pkgctx -- r dplyr --compact > dplyr.ctx.yaml

# Bioconductor package
nix run github:b-rodrigues/pkgctx -- r bioc:TCGAbiolinks --compact > tcgabiolinks.ctx.yaml

# GitHub package
nix run github:b-rodrigues/pkgctx -- r github:ropensci/rix --compact > rix.ctx.yaml

# Local package (current directory)
nix run github:b-rodrigues/pkgctx -- r . --compact > mypackage.ctx.yaml
```

### Python Package Sources

```bash
# PyPI package
nix run github:b-rodrigues/pkgctx -- python pandas --compact > pandas.ctx.yaml

# GitHub Python package
nix run github:b-rodrigues/pkgctx -- python github:psf/requests --compact > requests.ctx.yaml
```

### Command Line Options

| Option | Description |
|--------|-------------|
| `--format yaml\|json` | Output format (default: YAML) |
| `--compact` | Reduce output by ~67% |
| `--hoist-common-args` | Extract shared arguments to package level |
| `--include-internal` | Include non-exported functions |
| `--emit-classes` | Add class specs for Python |
| `--no-header` | Remove LLM instruction header |

### Recommended Flags for LLM Use

```bash
# Maximum compression for LLM context
nix run github:b-rodrigues/pkgctx -- r targets --compact --hoist-common-args > targets.ctx.yaml

# Python with class information
nix run github:b-rodrigues/pkgctx -- python numpy --compact --emit-classes > numpy.ctx.yaml
```

## Project Integration

**CENTRAL CACHE** — all ctx files live in ONE shared location (see `ctx-yaml-cache` rule):

    ~/docs_gh/proj/data/llm/content/inst/ctx/external/

Files are version-stamped: `{pkg}@{version}.ctx.yaml`. All projects share this cache. **NEVER store ctx in per-project `.claude/context/`** — that contradicts the central cache.

Quick start:

```bash
# Generate context for your own package
nix run github:b-rodrigues/pkgctx -- r . --compact > ~/docs_gh/proj/data/llm/content/inst/ctx/external/mypackage@0.1.0.ctx.yaml

# Reference in prompts — always use the central cache path
# cat ~/docs_gh/proj/data/llm/content/inst/ctx/external/targets@1.11.4.ctx.yaml

# Audit + sync for current project (reads DESCRIPTION, checks central cache)
source("~/docs_gh/llm/R/tar_plans/plan_pkgctx.R")
ctx_audit("DESCRIPTION")   # report gaps
ctx_sync("DESCRIPTION")    # fix gaps (generate missing, refresh stale)
```

## Version Compatibility with rix

Use `rix::available_dates()` to find snapshot dates. Key rules:
- **Start conservative** - Use dates 2-4 weeks before latest
- **Test locally** - Build the nix environment before committing
- **Document the date** - Include comment explaining why date was chosen
- **Don't chase latest** - Only update dates when you need new features

See [pkgctx-advanced.md](references/pkgctx-advanced.md#version-compatibility-with-rix) for date-finding code, version testing scripts, and detailed examples.

## CI Integration

Three GitHub Actions workflows are available for pkgctx automation:

1. **Auto-Update Package Context** - Regenerates `package.ctx.yaml` on push to main when R code changes
2. **API Drift Detection** - Warns on PRs when API has changed vs committed context
3. **Dependency Context Update** - Weekly scheduled job to refresh dependency context files

All workflows use `DeterminateSystems/nix-installer-action` and run on `ubuntu-latest`.

See [pkgctx-advanced.md](references/pkgctx-advanced.md#ci-integration) for complete workflow YAML files.

## Output Schema (v1.1)

Output uses YAML documents with `kind` field discriminators. Each document is one of: `context_header` (LLM instructions), `package` (metadata with schema version, name, version, language), `function` (signature, purpose, arguments, returns), or `class` (Python only, with methods).

See [pkgctx-advanced.md](references/pkgctx-advanced.md#output-schema-v11) for full schema examples.

## File Organization

```
CENTRAL CACHE (shared by all projects):
  ~/docs_gh/proj/data/llm/content/inst/ctx/external/
  ├── dplyr@1.1.4.ctx.yaml      # version-stamped
  ├── targets@1.11.4.ctx.yaml
  ├── duckdb@1.4.4.ctx.yaml
  └── ...                        # 70+ packages

PER PROJECT (auto-managed by plan_pkgctx.R):
  R/tar_plans/plan_pkgctx.R     # ctx_audit() + ctx_sync() functions
  _targets.R                     # plan_pkgctx() wired in
```

**DO NOT** create per-project `.claude/context/` directories. Use the central cache.

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Package not found on CRAN | Try `bioc:xyz` or `github:user/xyz` prefix |
| Nix build fails first time | Normal -- pkgctx itself is being built; subsequent runs use cache |
| Context too large | Add `--compact --hoist-common-args --no-header` |
| Internal functions missing | Add `--include-internal` (opt-in, not default) |

## Related Skills

- `nix-rix-r-environment` - Nix environment management, `available_dates()`
- `ci-workflows-github-actions` - CI workflow patterns
- `r-package-workflow` - R package development workflow
- `context-control` - Managing Claude Code context

## Resources

- **pkgctx repository**: https://github.com/b-rodrigues/pkgctx
- **rix package**: https://docs.ropensci.org/rix/
- **rstats-on-nix**: https://github.com/rstats-on-nix/nixpkgs
