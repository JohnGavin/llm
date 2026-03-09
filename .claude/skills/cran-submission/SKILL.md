---
name: cran-submission
description: >
  Prepare R packages for CRAN submission by checking for common ad-hoc requirements
  not caught by devtools::check(). Use when: (1) Preparing a package for first CRAN
  release, (2) Preparing a package update for CRAN resubmission, (3) Reviewing a
  package to ensure CRAN compliance, (4) Responding to CRAN reviewer feedback.
  Covers documentation requirements, DESCRIPTION field standards, URL validation,
  examples, and administrative requirements.
metadata:
  author: Garrick Aden-Buie (@gadenbuie)
  adapted-by: johngavin
  version: "1.0"
  source: posit-dev/skills (MIT)
---

# CRAN Extra Checks

Help R package developers prepare packages for CRAN submission by systematically checking for common ad-hoc requirements that CRAN reviewers enforce but `devtools::check()` doesn't catch.

## Workflow

1. **Initial Assessment**: Ask user if this is first submission or resubmission
2. **Run Standard Checklist**: Work through each item systematically (see below)
3. **Identify Issues**: As you review files, note specific problems
4. **Propose Fixes**: Suggest specific changes for each issue found
5. **Implement Changes**: Make edits only when user approves
6. **Verify**: Confirm all changes are complete

## Standard CRAN Preparation Checklist

Work through these items systematically:

1. **Create NEWS.md**: Run `usethis::use_news_md()` if not already present
2. **Create cran-comments.md**: Run `usethis::use_cran_comments()` if not already present
3. **Review README**:
   - Ensure it includes install instructions that will be valid when the package is accepted to CRAN (usually `install.packages("pkgname")`).
   - Check that it does not contain relative links. This works on GitHub but will be flagged by CRAN. Use full URLs to package documentation or remove the links.
   - Does the README clearly explain the package purpose and functionality?
   - **Important**: If README.Rmd exists, edit ONLY README.Rmd (README.md will be overwritten), then run `devtools::build_readme()` to re-render README.md
4. **Proofread DESCRIPTION**: Carefully review `Title:` and `Description:` fields (see detailed guidance below)
5. **Check function documentation**: Verify all exported functions have `@return` and `@examples` (see detailed guidance below)
6. **Verify copyright holder**: Check that `Authors@R:` includes a copyright holder with role `[cph]`
7. **Review bundled file licensing**: Check licensing of any included third-party files
8. **Run URL checks**: Use `urlchecker::url_check()` and fix any issues

## Detailed CRAN Checks

### Documentation Requirements

**Return Value Documentation (Strictly Enforced)**

CRAN now strictly requires `@return` documentation for all exported functions. Use the roxygen2 tag `@return` to document what the function returns.

- Required even for functions marked `@keywords internal`
- Required even if function returns nothing - document as `@return None` or similar
- Must be present for every exported function

Example:
```r
# Missing @return - WILL BE REJECTED
#' Calculate sum
#' @export
my_sum <- function(x, y) {
  x + y
}

# Correct - includes @return
#' Calculate sum
#' @param x First number
#' @param y Second number
#' @return A numeric value
#' @export
my_sum <- function(x, y) {
  x + y
}

# For functions with no return value
#' Print message
#' @param msg Message to print
#' @return None, called for side effects
#' @export
print_msg <- function(msg) {
  cat(msg, "\n")
}
```

**Examples for Exported Functions**

If your exported function has a meaningful return value, it will almost definitely require an `@examples` section. Use the roxygen2 tag `@examples`.

- Required even for functions marked `@keywords internal`
- Exceptions exist for functions used purely for side effects (e.g., creating directories)
- Examples must be executable

**Un-exported Functions with Examples**

If you write roxygen examples for un-exported functions, you must either:

1. Call them with `:::` notation: `pkg:::my_fun()`
2. Use `@noRd` tag to suppress `.Rd` file creation

**Using `\dontrun{}` Sparingly**

`\dontrun{}` should only be used if the example really cannot be executed (e.g., missing additional software, API keys, etc.).

- If showing an error, wrap the call in `try()` instead
- Consider custom predicates (e.g., `googlesheets4::sheets_has_token()`) with `if ()` blocks
- Sometimes `interactive()` can be used as the condition
- Lengthy examples (> 5 sec) can use `\donttest{}`

**Never Comment Out Code in Examples**

```r
# BAD - Will be rejected
#' @examples
#' # my_function(x)  # Don't do this!
```

CRAN's guidance: "Examples/code lines in examples should never be commented out. Ideally find toy examples that can be regularly executed and checked."

**Guarding Examples with Suggested Packages**

Use `@examplesIf` for entire example sections requiring suggested packages:

```r
#' @examplesIf rlang::is_installed("dplyr")
#' library(dplyr)
#' my_data %>% my_function()
```

For individual code blocks within examples:
```r
#' @examples
#' if (rlang::is_installed("dplyr")) {
#'   library(dplyr)
#'   my_data %>% my_function()
#' }
```

### DESCRIPTION Title Field

CRAN enforces strict Title requirements:

**Use Title Case**

Capitalize all words except articles like 'a', 'the'. Use `tools::toTitleCase()` to help format.

**Avoid Redundancy**

Common phrases that get flagged:
- "A Toolkit for" -> Remove
- "Tools for" -> Remove
- "for R" -> Remove

Examples:
```r
# BAD
Title: A Toolkit for the Construction of Modeling Packages for R

# GOOD
Title: Construct Modeling Packages
```

**Quote Software/Package Names**

Put all software and R package names in single quotes:

```r
# GOOD
Title: Interface to 'Tiingo' Stock Price API
```

**Length Limit**

Keep titles under 65 characters.

### DESCRIPTION Description Field

**Never Start With Forbidden Phrases**

CRAN will reject descriptions starting with:
- "This package"
- Package name
- "Functions for"

```r
# BAD
Description: This package provides functions for rendering slides.
Description: Functions for rendering slides to different formats.

# GOOD
Description: Render slides to different formats including HTML and PDF.
```

**Expand to 3-4 Sentences**

Single-sentence descriptions are insufficient. Provide a broader description of:
- What the package does
- Why it may be useful
- Types of problems it helps solve

**Quote Software Names, Not Functions**

```r
# BAD
Description: Uses 'case_when()' to process data.

# GOOD
Description: Uses case_when() to process data with 'dplyr'.
```

Software, package, and API names get single quotes (including 'R'). Function names do not.

**Expand All Acronyms**

All acronyms must be fully expanded on first mention:

```r
# BAD
Description: Implements X-SAMPA processing.

# GOOD
Description: Implements Extended Speech Assessment Methods Phonetic
    Alphabet (X-SAMPA) processing.
```

### URL and Link Validation

**All URLs Must Use HTTPS**

CRAN requires `https://` protocol for all URLs. HTTP links will be rejected.

**No Redirecting URLs**

CRAN rejects URLs that redirect to other locations.

**Use urlchecker Package**

```r
# Find redirecting URLs
urlchecker::url_check()

# Automatically update to final destinations
urlchecker::url_update()
```

**Ignore URLs That Will Exist After Publication**

Some URLs that don't currently resolve will exist once the package is published on CRAN. These should NOT be changed:

- CRAN badge URLs (e.g., `https://cran.r-project.org/package=pkgname`)
- CRAN status badges
- Package documentation URLs on r-universe or pkgdown sites

### Administrative Requirements

**Copyright Holder Role**

Always add `[cph]` role to Authors field:

```r
# Required
Authors@R: person("John", "Doe", role = c("aut", "cre", "cph"))
```

**LICENSE Year**

Update LICENSE year to current submission year.

## Final Verification Checklist

### Files and Structure
- [ ] `NEWS.md` exists and documents changes for this version
- [ ] `cran-comments.md` exists with submission notes
- [ ] If README.Rmd exists, it was edited (not README.md) and `devtools::build_readme()` was run
- [ ] README includes valid install instructions (`install.packages("pkgname")`)
- [ ] README has no relative links (all links are full URLs or removed)

### DESCRIPTION File
- [ ] `Title:` uses title case
- [ ] `Title:` has no redundant phrases ("A Toolkit for", "Tools for", "for R")
- [ ] `Title:` quotes all software/package names in single quotes
- [ ] `Title:` is under 65 characters
- [ ] `Description:` does NOT start with "This package", package name, or "Functions for"
- [ ] `Description:` is 3-4 sentences explaining purpose and utility
- [ ] `Description:` quotes software/package/API names (including 'R') but NOT function names
- [ ] `Description:` expands all acronyms on first mention
- [ ] `Authors@R:` includes copyright holder with `[cph]` role
- [ ] LICENSE year matches current submission year

### Function Documentation
- [ ] All exported functions have `@return` documentation
- [ ] All exported functions with meaningful returns have `@examples`
- [ ] No example sections use commented-out code
- [ ] Examples avoid `\dontrun{}` unless truly necessary
- [ ] Examples requiring suggested packages use `@examplesIf` or `if` guards
- [ ] Un-exported functions with examples use `:::` notation or `@noRd`

### URLs and Links
- [ ] `urlchecker::url_check()` was run
- [ ] All URLs use https protocol (no http links)
- [ ] No redirecting URLs (except aspirational CRAN badge URLs)
- [ ] No relative links in README that reference `.Rbuildignore` files

## Useful Tools

- `tools::toTitleCase()` - Format titles with proper capitalization
- `urlchecker::url_check()` - Find problematic URLs
- `urlchecker::url_update()` - Fix redirecting URLs
- `usethis::use_news_md()` - Create NEWS.md
- `usethis::use_cran_comments()` - Create cran-comments.md
- `devtools::build_readme()` - Re-render README.md from README.Rmd
- `usethis::use_tidy_description()` - Tidy up DESCRIPTION formatting

## Related Skills

- **r-cmd-check-fixes** - Fixes for `devtools::check()` failures (complementary)
- **r-package-workflow** - 9-step PR workflow
- **quality-gates** - Gold gate requires CRAN readiness
