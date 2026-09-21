# Companion: Portable Build Artifacts — Part 5 Incident Narrative

Dated incident narrative split out of the always-loaded
[`portable-build-artifacts`](../portable-build-artifacts.md) rule to keep it
under the repo's line-count budget. The normative content (When This
Applies, CRITICAL statement, Parts 1-5 required patterns and code examples,
Forbidden Patterns table, Origin, Related) stays in the rule; this file is
the full Part 5 observed-incident narrative, loaded on demand.

## Part 5 — full observed incident (tennis project, 2026-08-29)

Once a text file has large generated assets spliced into it as very long
single lines — a base64-encoded image, a minified data blob, any line
running into the tens of kilobytes — **line-oriented file APIs stop being
safe on that file**.

Observed directly: an R `readLines()` → `writeLines()` round-trip, used for
an unrelated structural edit (reordering a section) on an HTML file that
already had nine base64-encoded chart SVGs embedded as ~25KB single lines,
silently split one of those long lines into several. The split left the
*new*, correct data on the first fragment and seven *orphaned, stale* JSON
records trailing after it as inert text — a corruption that produced no
error, because the file was still syntactically plausible HTML. It was
caught only by chance, because a JS syntax check happened to be run before
publishing — not because anything required it.


## Sections Moved from the Rule Body (2026-09-21 line-limit pass)

Original verbatim text moved out of the rule; the normative summary stays in the rule.

```r
x <- readRDS("inst/extdata/vignettes/vig_github_activity_table.rds")
x$dependencies[[2]]$src$file
#> "/nix/store/y630zvw…-r-DT-0.34.0/library/DT/htmlwidgets/lib/datatables"
```

That path exists on the machine that ran the export and **nowhere else**. CI installs the same package at a different prefix and the render aborts:

```
Error: path for html_dependency not found: /nix/store/y630zvw…/lib/datatables
```

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

```r
# WRONG — line-oriented API on a file with embedded long lines
lines <- readLines("artifact.html")
lines[42] <- "<section>...</section>"
writeLines(lines, "artifact.html")   # risks silently splitting a nearby long line

# RIGHT — whole-file string substitution
content <- readChar("artifact.html", file.info("artifact.html")$size, useBytes = TRUE)
content <- sub(old_string, new_string, content, fixed = TRUE)
writeChar(content, "artifact.html", eos = NULL, useBytes = TRUE)
```

A build-time-loader / data-externalization redesign (embedded data → a
separately fetched asset, à la Observable Framework) is itself a change to
how a committed artifact is built — the same class of change Parts 1-5
govern. Two checks are required **before** starting the redesign, not after:

1. **Does the target platform actually support it?** A Claude Artifact's
   `assets` runtime capability was assumed available and was not — confirmed
   only by loading the `artifact-capabilities` skill directly and reading its
   authoritative capability list. Verify the mechanism exists on the actual
   target platform before designing around it; "it's a reasonable pattern"
   is not evidence it is buildable here.
2. **Does the incumbent pipeline already solve the problem this redesign is
   for?** A YAML→R-render pipeline in the `travel` project already produced
   fully-formed static HTML with a build-time privacy gate — architecturally
   ahead of the proposed fetch-a-JSON-asset model, not behind it. Redesigning
   it would have added a client-side dependency and moved private-data content
   out from behind a scanned build step, for no evidenced benefit. Read what
   actually built the artifact (check for a "Build" page, a `Makefile`, a
   render script) before assuming an artifact's surface shape *is* how it was
   authored.

Both checks failed to hold in a live investigation (2026-09) that started
from a plausible-sounding external pattern and two named artifacts. Full
narrative, evidence, and the disposition of every related issue:
[`lessons-learned-dashboard-data-separation`](https://github.com/JohnGavin/llm/blob/main/knowledge/wiki/lessons-learned-dashboard-data-separation.md)
(local-only knowledge base; not fetchable from a public clone).
