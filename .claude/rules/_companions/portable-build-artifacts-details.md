---
paths:
  - ".claude/rules/portable-build-artifacts.md"
---

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

## Part 7 — full incident narrative and detail (tennis, ISSUES.md #125, 2026-09-20)

`verify_artifact_publish.sh`-style checks (chart/heading/table counts, payload
hashes or asset ids) and a platform `action:"read"`/fetch of the published
document both operate on the artifact's **bytes**. Neither executes a single
line of its inline `<script>` content. A generated HTML+JS artifact can pass
every structural check, every publish, every re-fetch — while an uncaught JS
exception thrown partway through its own top-level script aborts every later
init statement in that script block, silently disabling everything downstream
(page/tab activation, chart image swaps, table population) with zero effect
on any byte-level check. This is Trap B from `verification-before-completion`
(inspects a different artifact than production uses) in a specific, common
shape: the artifact you diffed and the artifact a real browser *executes* are
the same bytes but not the same *check*.

`verify_html_artifact_js.sh` (JohnGavin/llm#1129) executes the real inline
scripts via jsdom (`runScripts: "dangerously"`) plus an eslint `no-undef`
sweep — reusable across projects, tune per-project naming conventions via
`--nav-attr`/`--tab-attr`/`--globals`/`--config` rather than forking it (see
`tennis`'s `scripts/verify_artifact_js.sh` for a worked per-project wrapper).
**A tool built for exactly this failure class already existing is not the
same as it being used** — this exact script existed, built from an earlier
incident in the same project, and was never wired into that project's own
publish workflow; the second incident happened anyway. If a project ships
generated interactive HTML, wire this (or an equivalent execute-the-real-script
check) into its own committed publish workflow, not just into institutional
memory of "a tool exists somewhere."

Why an isolated unit test of one extracted function fails to catch this: its
hand-built mock of the function's dependencies can silently diverge, in
construction order or shape, from what the real generated code produces.

**Second, independent defect from the same incident (fragment contract):** a
document meant to be a content *fragment* (no `<!doctype>`/`<html>`/`<head>`/
`<body>` of its own — e.g. the Claude Artifact tool's explicit contract, which
wraps published content in its own skeleton) can accumulate stray
full-document wrapper bytes at its very start or end and go undetected
indefinitely, because every routine review targets specific line numbers or
search patterns deep in the real content — never the literal first/last bytes
of the file. In the originating incident this had sat in the committed file
since a very old commit (a 14KB stray platform-wrapper preamble/trailing tag),
surviving every subsequent review, because the file's diffs are dominated by
large regenerated payloads that make a small anomaly at the very top invisible
in a normal review pass. **Required check:** for any file with a documented
"fragment only" contract, assert it does NOT start with
`<!doctype`/`<html`/`<head` and does NOT end with `</body>`/`</html>` — a
two-line grep, cheap enough to run on every publish.

**Related diff-reading trap, same incident:** `git diff --stat` (even with
`--no-ext-diff`) counts *logical lines* changed, not bytes. A file that is
mostly a small number of extremely long single lines (typical of minified
injected JS/data blobs in these artifacts) can have a multi-kilobyte chunk of
content added or removed while the diff stat reports something like "1
insertion, 1 deletion" — because the whole chunk was one unbroken line. Do
not use a small diff-stat as evidence that a change was small; check byte
counts (`wc -c`) directly when the file is known to contain long lines.

### Origin

`tennis` project, ISSUES.md #125, 2026-09-20 — an uncaught `TypeError` inside a
sparkline helper (`Array.indexOf(NaN)` always returns `-1`) aborted every later
init statement in the artifact's main `<script>` block; every existing check
(`node --check`, `verify_artifact_publish.sh`, an isolated unit test of one
function with a hand-built mock) passed throughout, because none of them
executed the real script. Root-caused only by loading the actual published
file into jsdom and executing it in document order. A 14KB stray
platform-wrapper preamble/trailing tag, present since a much older commit, was
found and removed in the same pass.
