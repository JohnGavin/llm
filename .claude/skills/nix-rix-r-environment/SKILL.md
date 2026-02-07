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

## Reference

*   [Troubleshooting](troubleshooting.md) - Fix common issues.
*   [Advanced Patterns](advanced-patterns.md) - Date selection, caching, GC roots.