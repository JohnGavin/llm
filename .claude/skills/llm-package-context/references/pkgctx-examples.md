# pkgctx Project Integration Examples

## Core Packages for llm Project

Generate context for frequently used packages:

```bash
# Core tidyverse/data manipulation
nix run github:b-rodrigues/pkgctx -- r dplyr --compact > .claude/context/dplyr.ctx.yaml
nix run github:b-rodrigues/pkgctx -- r tidyr --compact > .claude/context/tidyr.ctx.yaml
nix run github:b-rodrigues/pkgctx -- r purrr --compact > .claude/context/purrr.ctx.yaml
nix run github:b-rodrigues/pkgctx -- r tibble --compact > .claude/context/tibble.ctx.yaml

# Pipeline and workflow
nix run github:b-rodrigues/pkgctx -- r targets --compact > .claude/context/targets.ctx.yaml
nix run github:b-rodrigues/pkgctx -- r tarchetypes --compact > .claude/context/tarchetypes.ctx.yaml

# Git/GitHub operations
nix run github:b-rodrigues/pkgctx -- r gert --compact > .claude/context/gert.ctx.yaml
nix run github:b-rodrigues/pkgctx -- r gh --compact > .claude/context/gh.ctx.yaml
nix run github:b-rodrigues/pkgctx -- r usethis --compact > .claude/context/usethis.ctx.yaml

# Package development
nix run github:b-rodrigues/pkgctx -- r devtools --compact > .claude/context/devtools.ctx.yaml
nix run github:b-rodrigues/pkgctx -- r testthat --compact > .claude/context/testthat.ctx.yaml
nix run github:b-rodrigues/pkgctx -- r pkgdown --compact > .claude/context/pkgdown.ctx.yaml

# Nix/reproducibility
nix run github:b-rodrigues/pkgctx -- r github:ropensci/rix --compact > .claude/context/rix.ctx.yaml

# Utilities
nix run github:b-rodrigues/pkgctx -- r logger --compact > .claude/context/logger.ctx.yaml
nix run github:b-rodrigues/pkgctx -- r fs --compact > .claude/context/fs.ctx.yaml
nix run github:b-rodrigues/pkgctx -- r here --compact > .claude/context/here.ctx.yaml
nix run github:b-rodrigues/pkgctx -- r glue --compact > .claude/context/glue.ctx.yaml
```

## Project-Specific Packages (coMMpass Example)

```bash
# Bioconductor data access
nix run github:b-rodrigues/pkgctx -- r bioc:TCGAbiolinks --compact > .claude/context/TCGAbiolinks.ctx.yaml
nix run github:b-rodrigues/pkgctx -- r bioc:GenomicDataCommons --compact > .claude/context/GenomicDataCommons.ctx.yaml
nix run github:b-rodrigues/pkgctx -- r bioc:SummarizedExperiment --compact > .claude/context/SummarizedExperiment.ctx.yaml

# AWS access
nix run github:b-rodrigues/pkgctx -- r aws.s3 --compact > .claude/context/aws.s3.ctx.yaml

# Parallel processing
nix run github:b-rodrigues/pkgctx -- r mirai --compact > .claude/context/mirai.ctx.yaml
nix run github:b-rodrigues/pkgctx -- r nanonext --compact > .claude/context/nanonext.ctx.yaml
```

## Generate Context for Current Project

```bash
# Generate context for your own package
nix run github:b-rodrigues/pkgctx -- r . --compact > package.ctx.yaml

# Commit to version control
git add package.ctx.yaml
git commit -m "Add package API context for LLM use"
```

## Using Context in Prompts

### Including in Claude Code

Reference `.ctx.yaml` files in your prompts:

```
Based on the targets package API in .claude/context/targets.ctx.yaml,
help me create a pipeline that...
```

### Concatenating Multiple Contexts

```bash
# Combine relevant package contexts for a task
cat .claude/context/targets.ctx.yaml \
    .claude/context/tarchetypes.ctx.yaml \
    .claude/context/dplyr.ctx.yaml > combined.ctx.yaml
```
