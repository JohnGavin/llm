# Nix and Rix for Reproducible R Environments

## Description

This skill covers setting up and working within reproducible R development environments using Nix and the rix R package.

## Core Concepts

- **Reproducibility**: Lock package versions via nix. Same environment locally and in CI/CD.
- **Persistent Shell**: Use ONE persistent nix shell for all work in a session.
- **rix**: R package to generate nix configurations.

## Quick Start

### 1. Generating the Environment (default.R)

```r
library(rix)

rix(
  r_ver = "2024-11-01", # Determines package versions
  r_pkgs = c("devtools", "targets", "dplyr"),
  system_pkgs = c("git", "quarto"),
  project_path = ".",
  overwrite = TRUE
)
# Then run source("default.R") to create default.nix
```

### 2. Entering the Shell

```bash
# Enter nix shell (downloads/builds first time)
nix-shell default.nix

# Verify you are in nix
echo $IN_NIX_SHELL # should be "impure"
which R            # should be /nix/store/...
```

## Workflow

**DO:** Work inside the persistent shell for everything.
```bash
nix-shell default.nix
R  # Launch R
# ... do work ...
git status
exit
```

**DON'T:** Launch new shells for single commands.
```bash
# BAD
nix-shell --run "Rscript ..."
```

## DESCRIPTION as Single Source of Truth (MANDATORY)

**NEVER maintain a separate package list for Nix.** All R package deps MUST be
extracted from DESCRIPTION by `default.R` using `read.dcf("DESCRIPTION")`.

### Mandatory `default.R` pattern

```r
library(rix)
desc_raw <- read.dcf("DESCRIPTION")
parse_field <- function(field) {
  if (!field %in% colnames(desc_raw)) return(character())
  pkgs <- strsplit(desc_raw[, field], ",\\s*|\n\\s*")[[1]]
  gsub("\\s*\\([^)]+\\)", "", trimws(pkgs)) |>
    (\(x) x[nzchar(x) & !is.na(x)])()
}
desc_deps <- unique(c(parse_field("Imports"), parse_field("Suggests")))
dev_extras <- c("mirai", "nanonext", "usethis", "gert", "gh",
                "pkgdown", "styler", "air", "spelling")
r_pkgs <- unique(c(desc_deps, dev_extras)) |> sort()
```

### Safe regeneration in `default.sh`

NEVER use `curl -sl` to fetch a remote rix expression. Use `import <nixpkgs> {}`:

```bash
nix-shell \
  --expr "let pkgs = import <nixpkgs> {}; in pkgs.mkShell {
    buildInputs = [ pkgs.R pkgs.rPackages.rix pkgs.rPackages.cli
                    pkgs.rPackages.curl pkgs.curlMinimal pkgs.cacert ]; }" \
  --command "Rscript --vanilla default.R"
```

Why: `import <nixpkgs>` uses the ambient channel, always matching pre-built
binaries. The curl-fetched expression can introduce R version mismatches causing
`dyn.load` segfaults.

### Drift detection

Every project MUST include `R/tar_plans/plan_nix_sync.R` with targets that compare
DESCRIPTION deps vs `default.nix` rpkgs, warning on drift. Include
`R/utils_nix.R` with `get_description_deps()`.

### Cachix push CI

Every project SHOULD include a CI workflow that runs `./push_to_cachix.sh` after
the package check passes on main, using `cachix watch-exec`.

**Reference:** coMMpass project (Feb 2026).

## CLI Tools Not on PATH (CRITICAL)

When a CLI tool (cachix, git-lfs, quarto, etc.) isn't available in the
current shell, use `nix-shell -p` to get it instantly:

```bash
# Pattern: nix-shell -p <tool> --run "<command>"
nix-shell -p cachix --run "./push_to_cachix.sh"
nix-shell -p git-lfs --run "git lfs pull"
nix-shell -p quarto --run "quarto render vignette.qmd"

# Combine multiple tools:
nix-shell -p cachix -p git-lfs --run "git lfs pull && ./push_to_cachix.sh"
```

**NEVER** declare a step impossible because a tool isn't on PATH.
`nix-shell -p` solves this in seconds.

**Common tools available via `nix-shell -p`:**
- `cachix` — Nix binary cache management
- `git-lfs` — Git Large File Storage
- `quarto` — Document rendering
- `pandoc` — Document conversion
- `gh` — GitHub CLI

## Reference

*   [Troubleshooting](troubleshooting.md) - Fix common issues.
*   [Advanced Patterns](advanced-patterns.md) - Date selection, caching, GC roots.