# Recipe: Deploy a New R Package Project

## Prerequisites
- GitHub repo created
- Nix dev shell available (`echo $IN_NIX_SHELL` = 1)

## Steps

### 1. Package scaffold
```r
usethis::create_package("~/docs_gh/project-name")
usethis::use_mit_license()
usethis::use_testthat()
usethis::use_git()
```

### 2. DESCRIPTION
Fill in Title, Description, Authors. Add Imports as needed.

### 3. Nix environment
```r
# In default.R:
rix::rix(r_ver = "2026-04-01", r_pkgs = c(...), ide = "none", project_path = ".")
```
```bash
nix-shell ~/docs_gh/rix.setup/default.nix --run "Rscript /path/to/project/default.R"
```

### 4. Per-project CLAUDE.md
Copy from `~/.claude/templates/new-project-claude.md`, fill in project details.

### 5. CI workflow
```bash
usethis::use_github_action("check-standard")
```

### 6. pkgdown site
```r
usethis::use_pkgdown()
# Build locally, push gh-pages (bslib breaks in Nix)
```

### 7. Verify
```bash
nix-shell /path/to/project/default.nix --run "Rscript -e 'devtools::check()'"
```
