# R CMD Check Common Fixes

## Description

Quick reference for fixing common R CMD check errors and warnings when setting up new R packages. These issues appear frequently and have standard solutions.

## Purpose

Use this skill when:
- Setting up a new R package
- Running `devtools::check()` for the first time
- Debugging R CMD check failures in CI
- Preparing a package for CRAN submission

## Common Issues and Fixes

### 1. Examples Try to Read Non-Existent Files

**Error:**
```
checking examples ... ERROR
Error: No files found that match the pattern "inst/extdata/*.parquet"
```

**Fix:** Wrap examples in `\dontrun{}` or `\donttest{}`:

```r
#' @examples
#' \dontrun{
#' # Query recent data
#' df <- query_data(date_range = c(Sys.Date() - 30, Sys.Date()))
#' }
```

**When to use which:**
- `\dontrun{}` - Example requires external resources (files, APIs, database)
- `\donttest{}` - Example works but takes too long for CRAN checks

---

### 2. Non-ASCII Characters in R Code

**Warning:**
```
checking code files for non-ASCII characters ... WARNING
Found the following files with non-ASCII characters:
  R/email_summary.R
```

**Common culprits:**
- Emojis: `"📊"`, `"✓"`, `"⚠️"`
- Degree symbol: `"°C"`
- Smart quotes: `"..."` instead of `"..."`
- En/em dashes: `–` or `—`

**Fix:** Replace with ASCII alternatives or escape sequences:

```r
# Before (non-ASCII):
message("Temperature: 25°C")
cat("⚠️ Warning!")

# After (ASCII):
message("Temperature: 25 C")
cat("[!] Warning!")

# Or use Unicode escapes:
message("Temperature: 25\u00B0C")  # degree symbol
```

---

### 3. Unused Imports in DESCRIPTION

**Warning:**
```
Namespaces in Imports field not imported from:
  'rlang' 'tidyr'
All declared Imports should be used.
```

**Fix:** Either use the packages or remove them from DESCRIPTION:

```r
# In DESCRIPTION, remove unused packages:
Imports:
    dplyr,
    # rlang,  # Remove if not used
    # tidyr,  # Remove if not used
    utils
```

**Check actual usage:**
```bash
grep -r "rlang::" R/
grep -r "tidyr::" R/
```

---

### 4. Missing or Unexported Objects

**Warning:**
```
Missing or unexported object: 'arrow::ParquetWriteOptions'
```

**Cause:** Using internal/unexported functions or R6 class methods.

**Fix:** Use documented public API instead:

```r
# Before (using internal API):
write_options <- arrow::ParquetWriteOptions$create(compression = "zstd")
arrow::write_dataset(data, path, parquet_options = write_options)

# After (using public API):
arrow::write_parquet(data, path, compression = "zstd")
```

---

### 5. Undefined Global Variables (NSE)

**Note:**
```
Undefined global functions or variables:
  station_id tail time
```

**Cause:** dplyr/tidyverse NSE (non-standard evaluation) uses column names as variables.

**Fix:** Add globalVariables declaration in package documentation:

```r
# R/mypackage-package.R
#' @keywords internal
"_PACKAGE"

## usethis namespace: start
#' @importFrom utils tail
## usethis namespace: end
NULL

# Declare NSE variables
utils::globalVariables(c("time", "station_id", "year", "month"))
```

---

### 6. Non-Standard Files at Top Level

**Note:**
```
Non-standard file/directory found at top level:
  'README.qmd'
```

**Fix:** Add to `.Rbuildignore`:

```
^README\.qmd$
^README\.Rmd$
^.*\.Rproj$
^\.Rproj\.user$
^nix-shell-root$
^default\.R$
^default\.nix$
^default\.sh$
```

---

### 7. License Stub Invalid

**Note:**
```
License stub is invalid DCF.
```

**Fix:** Ensure LICENSE file format matches DESCRIPTION:

```r
# In DESCRIPTION:
License: MIT + file LICENSE

# In LICENSE file (exactly this format):
YEAR: 2024
COPYRIGHT HOLDER: Your Name
```

Or use usethis:
```r
usethis::use_mit_license("Your Name")
```

---

### 8. importFrom for Base Functions

**Note:**
```
Consider adding
  importFrom("stats", "time")
  importFrom("utils", "tail")
to your NAMESPACE file.
```

**Fix:** Use explicit namespace or import:

```r
# Option 1: Explicit namespace (preferred)
utils::tail(date_seq, 1)

# Option 2: Import in package documentation
#' @importFrom utils tail
```

---

## Quick Checklist for New Packages

Before running `devtools::check()`:

- [ ] All examples either work or are wrapped in `\dontrun{}`
- [ ] No emojis or special characters in R code
- [ ] All DESCRIPTION Imports are actually used
- [ ] NSE variables declared with `globalVariables()`
- [ ] `utils::` prefix for base functions like `tail`, `head`
- [ ] `.Rbuildignore` includes non-standard files
- [ ] LICENSE file matches DESCRIPTION format

## Automated Fixes

```r
# Find non-ASCII characters
tools::showNonASCIIfile("R/myfile.R")

# Check all files
for (f in list.files("R", "\\.R$", full.names = TRUE)) {
  result <- tools::showNonASCIIfile(f)
  if (length(result) > 0) cat(f, "has non-ASCII\n")
}

# Find unused imports
# Run devtools::check() and look at the warnings
```

## ERDDAP-Specific Issue

When working with ERDDAP data sources (Marine Institute, NOAA, etc.):

**Problem:** CSV parsing creates wrong column names
```
Error: Column `utc` does not exist in target table
```

**Cause:** ERDDAP CSV files have TWO header rows:
1. Column names: `time,station_id,...`
2. Units: `UTC,unitless,...`

Using `read.csv(..., skip = 1)` skips column names and uses units as headers.

**Fix:**
```r
# Remove the units row while keeping column names
csv_text <- httr2::resp_body_string(response)
csv_lines <- strsplit(csv_text, "\n")[[1]]
csv_lines <- csv_lines[-2]  # Remove units row (index 2)
data <- utils::read.csv(text = paste(csv_lines, collapse = "\n"))
```

## Related Skills

- `r-package-workflow` - Full 9-step development workflow
- `ci-workflows-github-actions` - CI setup for R packages
- `nix-rix-r-environment` - Reproducible R environments
- `test-driven-development` - Writing tests first
