# Nix Drift Detection

Detect when DESCRIPTION changes but default.nix hasn't been regenerated.

## When to Use

- After adding/removing packages from DESCRIPTION
- In CI/CD pipelines to catch drift
- As a targets plan to continuously monitor sync status

## The Problem

When developing R packages with rix/nix:
1. You add a package to DESCRIPTION (e.g., new Import)
2. You forget to regenerate default.nix
3. CI passes (using old nix env) but local dev breaks, or vice versa

## Solution

A targets plan that:
1. Tracks DESCRIPTION as a file target
2. Extracts Imports + Suggests
3. Compares against packages in default.nix
4. Alerts on drift

## Implementation

### Helper Function

Add to `R/utils_nix.R` or similar:

```r
#' Extract package dependencies from DESCRIPTION
#'
#' Parses Imports and Suggests fields, removes version constraints,
#' excludes base R packages.
#'
#' @param desc_path Path to DESCRIPTION file
#' @return Character vector of package names
#' @export
get_description_deps <- function(desc_path = "DESCRIPTION") {
  if (!file.exists(desc_path)) {
    return(character())
  }

  desc <- read.dcf(desc_path)

  # Extract Imports and Suggests
  imports <- if ("Imports" %in% colnames(desc)) {
    strsplit(desc[, "Imports"], ",\\s*|\n\\s*")[[1]]
  } else {
    character()
  }

  suggests <- if ("Suggests" %in% colnames(desc)) {
    strsplit(desc[, "Suggests"], ",\\s*|\n\\s*")[[1]]
  } else {
    character()
  }

  # Clean package names (remove version constraints like ">= 1.0")
  clean_pkg <- function(x) {
    gsub("\\s*\\([^)]+\\)", "", trimws(x))
  }

  deps <- unique(c(sapply(imports, clean_pkg), sapply(suggests, clean_pkg)))
  deps <- deps[deps != "" & !is.na(deps)]

  # Exclude base R packages (always available)
  base_pkgs <- c(
    "stats", "graphics", "grDevices", "utils", "datasets",
    "methods", "base", "tools", "parallel", "compiler",
    "grid", "splines", "stats4", "tcltk"
  )

  deps[!deps %in% base_pkgs]
}
```

### Targets Plan

Add to `R/tar_plans/plan_nix_sync.R`:

```r
# plan_nix_sync.R - DESCRIPTION/default.nix drift detection
# Ensures DESCRIPTION is the single source of truth for R dependencies.

plan_nix_sync <- list(
  # Track DESCRIPTION file changes
  targets::tar_target(
    nix_desc_file,
    "DESCRIPTION",
    format = "file"
  ),

  # Extract Imports + Suggests from DESCRIPTION
  targets::tar_target(
    nix_desc_deps,
    get_description_deps(nix_desc_file)
  ),

  # Compare DESCRIPTION deps vs default.nix packages
  targets::tar_target(
    nix_sync_check,
    {
      # Read default.nix and extract package names
      nix_content <- readLines("default.nix", warn = FALSE)

      # Extract from 'inherit (pkgs.rPackages)' blocks
      inherit_lines <- grep("inherit.*rPackages", nix_content)
      nix_pkgs <- character()

      for (i in seq_along(nix_content)) {
        line <- trimws(nix_content[i])
        # Package names are lowercase identifiers after inherit block
        if (grepl("^[a-zA-Z][a-zA-Z0-9.]*;?$", line)) {
          pkg <- gsub(";$", "", line)
          if (nchar(pkg) > 1 && nchar(pkg) < 30) {
            nix_pkgs <- c(nix_pkgs, pkg)
          }
        }
      }

      nix_pkgs <- unique(nix_pkgs)

      # Dev tools that are in nix but not necessarily in DESCRIPTION
      dev_extras <- c(
        "rix", "devtools", "usethis", "pkgload", "gert", "gh",
        "styler", "languageserver", "pkgdown", "covr", "testthat"
      )

      # Check drift
      desc_deps <- nix_desc_deps
      missing_from_nix <- setdiff(desc_deps, nix_pkgs)
      extra_in_nix <- setdiff(nix_pkgs, c(desc_deps, dev_extras))

      drift_detected <- length(missing_from_nix) > 0

      if (drift_detected) {
        cli::cli_alert_danger(
          "DESCRIPTION/default.nix DRIFT: {length(missing_from_nix)} package(s) missing"
        )
        cli::cli_alert_info("Missing: {paste(missing_from_nix, collapse = ', ')}")
        cli::cli_alert_info("Run: Rscript default.R && nix-shell default.nix")
      } else {
        cli::cli_alert_success("DESCRIPTION and default.nix are in sync")
      }

      list(
        drift_detected = drift_detected,
        missing_from_nix = missing_from_nix,
        extra_in_nix = extra_in_nix,
        desc_deps = desc_deps,
        nix_pkgs = nix_pkgs,
        checked_at = Sys.time()
      )
    },
    cue = targets::tar_cue(mode = "always")
  ),

  # Track default.nix for downstream dependencies
  targets::tar_target(
    nix_default_nix,
    "default.nix",
    format = "file"
  )
)
```

### Add to _targets.R

```r
# In _targets.R, source and combine:
source("R/tar_plans/plan_nix_sync.R")

c(
  plan_nix_sync,
  # ... other plans
)
```

## CI Integration

Add drift check to GitHub Actions:

```yaml
- name: Check nix drift
  run: |
    nix-shell default.nix --run "Rscript -e '
      targets::tar_make(nix_sync_check)
      result <- targets::tar_read(nix_sync_check)
      if (result\$drift_detected) {
        stop(\"DESCRIPTION/default.nix drift detected!\")
      }
    '"
```

## Pre-commit Hook

Add to `.git/hooks/pre-commit`:

```bash
#!/bin/bash
# Check for DESCRIPTION changes without corresponding default.nix changes
if git diff --cached --name-only | grep -q "^DESCRIPTION$"; then
  if ! git diff --cached --name-only | grep -q "^default.nix$"; then
    echo "WARNING: DESCRIPTION changed but default.nix not updated"
    echo "Run: Rscript default.R"
    # Uncomment to block commit:
    # exit 1
  fi
fi
```

## Related

- `nix-rix-r-environment` skill - Environment setup
- `r-package-workflow` skill - 9-step workflow includes nix regeneration
