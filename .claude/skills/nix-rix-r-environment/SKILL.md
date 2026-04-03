---
name: nix-rix-r-environment
description: Use when setting up reproducible R environments with Nix and rix, troubleshooting Nix shell issues, managing R package dependencies in Nix, or detecting environment drift. Triggers: Nix, rix, Nix shell, reproducible environment, nix-shell, R environment, segfault.
---
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

## 5 Common Mistakes

```bash
# MISTAKE 1: Installing packages inside Nix shell
# WRONG:
install.packages("dplyr")  # Breaks reproducibility!
# RIGHT: Add to DESCRIPTION -> edit default.R -> exit -> re-enter Nix

# MISTAKE 2: Nested shells causing R version mismatch
# WRONG:
nix-shell default.nix  # Already in a shell!
# Check first:
echo $IN_NIX_SHELL  # Should be empty if not in a shell
# Symptom: Segfaults from mixed R versions

# MISTAKE 3: Not using GC root (shell rebuilds every time)
# WRONG:
nix-shell default.nix
# RIGHT: Use default.sh which creates a GC root
./default.sh  # Creates result symlink, prevents garbage collection

# MISTAKE 4: Editing default.nix directly
# WRONG:
vim default.nix  # Manual edits get overwritten
# RIGHT: Edit default.R, then run it to regenerate default.nix
Rscript default.R  # Regenerates default.nix from rix()

# MISTAKE 5: Wrong R version causing segfaults
# WRONG: Using a date that gives R 4.4.x when packages need R 4.5.x
rix(r_ver = "2024-06-01", ...)
# RIGHT: Check available dates for your R version
rix::available_dates()  # Find dates with R 4.5.x
```

## Drift Detection

Detect when DESCRIPTION changes but default.nix hasn't been regenerated. Includes a targets plan, helper function, CI integration, and pre-commit hook.

See [drift-detection.md](references/drift-detection.md) for full implementation.

## Reference

*   [Troubleshooting](references/troubleshooting.md) - Fix common issues.
*   [Advanced Patterns](references/advanced-patterns.md) - Date selection, caching, GC roots.
*   [Drift Detection](references/drift-detection.md) - DESCRIPTION/default.nix sync check.