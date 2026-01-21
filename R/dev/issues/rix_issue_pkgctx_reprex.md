# rix Issue: Improve error message when git_pkgs repo has no DESCRIPTION file

## Title
`git_pkgs`: Cryptic error "argument is of length zero" when repo is not an R package

## Reprex

```r
library(rix)

# pkgctx is a Rust CLI tool, not an R package (no DESCRIPTION file)
# https://github.com/b-rodrigues/pkgctx
packages <- list(
  list(
    package_name = "pkgctx",
    repo_url = "https://github.com/b-rodrigues/pkgctx",
    commit = "a8a26defc739805110cc9e36d6813c5e99fd480f"
  )
)

rix(
  r_ver = "4.5.2",
  git_pkgs = packages,
  project_path = tempdir(),
  overwrite = TRUE
)
#> Error in if (grepl("\\.tar\\.gz", path)) { : argument is of length zero
```

## Traceback

```
15: get_imports(desc_path, commit_date, ...)
14: hash_url(url, repo_url, commit, ...)
13: hash_git(repo_url = repo_url, commit, ...)
12: nix_hash(repo_url, commit, ...)
11: fetchgit(pkg, ...)
10: FUN(X[[i]], ...)
 9: lapply(git_pkgs, function(pkg) fetchgit(pkg, ...))
...
 1: rix(...)
```

## Root Cause

The `pkgctx` repository is a **Rust CLI tool** (contains `Cargo.toml`, `src/`), not an R package. It has no `DESCRIPTION` file.

The `get_imports()` function in `R/nix_hash.R` searches for DESCRIPTION but finds nothing, resulting in an empty `path` variable that causes the cryptic error.
## Expected Behavior

A clearer error message such as:

```
Error: No DESCRIPTION file found in repository 'https://github.com/b-rodrigues/pkgctx'.
The `git_pkgs` argument expects R packages with a DESCRIPTION file.
```

## Session Info

```
R version: 4.5.2 (2025-10-31)
Platform: aarch64-apple-darwin24.6.0
OS: Darwin 25.2.0
rix version: 0.17.2
```

## Related

- Issue #371 addressed the opposite case (`length > 1` when multiple DESCRIPTION files exist)
- PR #372 fixed that case

This issue requests handling the `length == 0` case with a user-friendly error message.
