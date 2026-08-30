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
