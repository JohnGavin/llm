# Companion: Portable Build Artifacts — Worked Code Examples

Worked code examples split out of the always-loaded
[`portable-build-artifacts`](../portable-build-artifacts.md) rule to keep it
under the rules size limit. The normative content (the two-failure-mode
table, the three read-time-repair properties, Parts 2-4, Forbidden Patterns,
Origin) stays in the rule; this file is the runnable snippets, loaded on
demand.

## Part 1 — the symptom, reproduced

```r
x <- readRDS("inst/extdata/vignettes/vig_github_activity_table.rds")
x$dependencies[[2]]$src$file
#> "/nix/store/y630zvw…-r-DT-0.34.0/library/DT/htmlwidgets/lib/datatables"
```

That path exists on the machine that ran the export and **nowhere else**. CI
installs the same package at a different prefix and the render aborts:

```
Error: path for html_dependency not found: /nix/store/y630zvw…/lib/datatables
```

## Part 1 — read-time repair, worked R snippet

```r
# For each dependency whose recorded path is absent on THIS machine,
# re-resolve it from the installed package.
if (!file.exists(f) && !dir.exists(f)) {
  m <- regmatches(f, regexec("/library/([^/]+)/(.*)$", f))[[1]]
  if (length(m) == 3L) {
    resolved <- system.file(m[3], package = m[2])
    if (nzchar(resolved)) dep$src$file <- resolved
  }
}
```
