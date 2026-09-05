---
paths:
  - "**/data-raw/**"
  - "**/inst/extdata/**"
  - "**/R/tar_plans/**"
  - "**/_includes/**"
  - "**/_targets.R"
  - "**/scripts/**/*.R"
  - "**/*.html"
---

# Rule: Portable Build Artifacts

## When This Applies

Any time a build **writes a file that gets committed** — a serialised object (`.rds`, `.parquet`, `.qs`), a rendered HTML page, a generated config — and that file is later read by a *different* machine (CI, a colleague, a deploy runner) or from a *different checkout* (a worktree, a fresh clone).

## CRITICAL: The Checkout That Built It Must Not Leak Into It

A committed artifact is only reproducible if it is **independent of where it was built**. Two failure modes, both observed in `llm` within 48 hours, both of which merged green and were only caught days later by a CI render log:

| Leak | What gets baked in | Symptom |
|---|---|---|
| **Absolute paths inside serialised objects** | The builder's filesystem layout | Renders locally, dies in CI |
| **Path filters matched against absolute paths** | The builder's checkout location | Silently produces *empty* output |

The second is far more dangerous: it does not error, it returns nothing.

## Part 1: Serialised objects capture absolute paths

`saveRDS()` preserves an object's internals verbatim, **including absolute filesystem paths the object captured at construction time**. The clearest case is `htmltools::htmlDependency()`, which every htmlwidget carries:

```r
x <- readRDS("inst/extdata/vignettes/vig_github_activity_table.rds")
x$dependencies[[2]]$src$file
#> "/nix/store/y630zvw…-r-DT-0.34.0/library/DT/htmlwidgets/lib/datatables"
```

That path exists on the machine that ran the export and **nowhere else**. CI installs the same package at a different prefix and the render aborts:

```
Error: path for html_dependency not found: /nix/store/y630zvw…/lib/datatables
```

### Required pattern — repair at READ time, never by regenerating

Regenerating the artifact does **not** fix this — it only re-acquires whichever path the *new* exporting machine has, so the defect returns on the next export from anywhere else. Repair when the artifact is loaded:

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

Three properties this must have: **no-op when the path already resolves** (changes nothing on the machine that wrote the artifact); **leave `package`-relative dependencies alone** (already portable); **leave unresolvable paths at their original value** — do not blank them, a visible failure beats a silently-missing asset.

Same hazard class, worth checking for: fonts resolved to absolute paths, cached `system.file()` results, `here::here()` values captured into a stored object, open connections, and `environment()` captured by closures inside the object.

## Part 2: Path filters must match RELATIVE to the scan root

An exclusion intended to skip *nested* subtrees must never be matched against the absolute path, because the **scan root itself** may contain the excluded token.

```r
# WRONG — the scan root can contain the token
files <- files[!grepl("/(archive|worktrees)/", files)]

# RIGHT — only genuinely nested subtrees are dropped
rel   <- fs::path_rel(files, scan_root)
files <- files[!grepl("(^|/)(archive|worktrees)/", rel)]
```

Why it matters here: **every** worktree path contains `/worktrees/` — both `.claude/worktrees/` (every dispatched agent) and `~/docs_gh/worktrees/` (every manual worktree, per `worktree-location`). So a target built anywhere except the main checkout scanned 377 files and kept **zero**. The result is not an error — it is a well-formed, empty result that flows downstream and only surfaces somewhere far away (in the observed case, a `facet_wrap()` call in a vignette that killed the entire site build).

## Part 3: Verify artifacts by content, not by existence

Both incidents passed every gate in place at the time:

| Gate | What it checked | Why it missed this |
|---|---|---|
| `qa_no_nulls` | value is not `NULL` | a zero-row tibble is not `NULL` |
| `qa_rds_freshness` | snapshot mtime vs target mtime | never inspects content |
| CI / deploy status | workflow exit code | the data path was not in `on.push.paths` |

**Before committing a regenerated artifact, diff it against the previous version's content** — row count, category coverage, non-NA share — not just its existence or timestamp. A regeneration that shrinks an artifact by orders of magnitude is a defect until proven otherwise:

```r
old <- readRDS(...); new <- <rebuild>
stopifnot(nrow(new) >= 0.5 * nrow(old))   # tune per artifact
```

## Part 4: Prefer the canonical checkout for regeneration

Until an exporter is proven location-independent, regenerate committed artifacts **from the project's main checkout**, not from a worktree. Where that cannot be guaranteed, have the exporter print the checkout path it ran from, so a worktree-built artifact is visible in review rather than silent.

## Part 5: Large embedded assets make a file line-unsafe

Once a text file has large generated assets spliced into it as very long single lines — a base64-encoded image, a minified data blob, any line running into the tens of kilobytes — **line-oriented file APIs stop being safe on that file**. Observed directly on the `tennis` project (2026-08-29): an R `readLines()`/`writeLines()` round-trip silently split an embedded ~25KB base64 SVG line, orphaning seven stale JSON records with no error — caught only by an incidental syntax check before publish. Full incident narrative: companion doc.

### Required pattern

**Once a file crosses this threshold, use whole-file string operations only** — `readChar()`/`writeChar()` in R, never `readLines()`/`writeLines()`, never `sed` with line addressing; don't mix the two styles on the same file. **Splice large generated assets last** — do structural/text edits on the small, clean version first, embed large assets as the final build step. **Verify structural integrity after every edit** — a syntax check for embedded code, a tag/section-balance count, a record-count sanity check; do not treat "the edit tool reported success" as sufficient, since a corrupted file can still write successfully.

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

## Part 6: Before re-architecting a dashboard's data-delivery mechanism, verify the capability and the incumbent pipeline

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

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---|---|---|
| `saveRDS()` an htmlwidget and assume it is portable | Absolute asset paths baked in | Repair on read (Part 1) |
| "Just regenerate it" to fix a path error | Re-acquires the new machine's path | Repair on read, not on write |
| `grepl("/token/", absolute_path)` to skip subtrees | Matches the scan root too | Match relative to the root (Part 2) |
| Accepting a regenerated artifact because it is non-NULL | Empty ≠ NULL | Compare content to the prior version (Part 3) |
| Treating "CI green" as "artifact correct" | The data path may not even trigger CI | Verify the deployed artifact |
| `readLines()`/`writeLines()` on a file with embedded long lines | Can silently split a long line, orphaning data | Whole-file string ops only (Part 5) |
| Considering an edit done because the tool call succeeded | A corrupted file can still write successfully | Structural integrity check before publish (Part 5) |
| Redesigning a dashboard's data delivery around a platform capability that was never confirmed to exist | Assumed feasibility, not verified feasibility | Load the capability's own authoritative docs first (Part 6) |
| Replacing an existing build pipeline without reading what it already does | May already be a better instance of the pattern you're about to add | Read the artifact's own build trail before redesigning it (Part 6) |

## Origin

- [llm#883](https://github.com/JohnGavin/llm/issues/883) / [#885](https://github.com/JohnGavin/llm/pull/885) — DT `html_dependency` absolute nix paths; 13 snapshots affected; blocked all publishing for 2 days
- [llm#889](https://github.com/JohnGavin/llm/issues/889) / [#890](https://github.com/JohnGavin/llm/pull/890) — worktree-exclusion regex matched its own scan root; `vig_scrolly_config` regenerated 222 rows → 0 by [#868](https://github.com/JohnGavin/llm/pull/868) and shipped silently
- `tennis` project, 2026-08-29 — `readLines()`/`writeLines()` round-trip silently split an embedded ~25KB data line, orphaning stale records (Part 5; full narrative in companion doc)
- [llm#1163](https://github.com/JohnGavin/llm/issues/1163) — Observable Framework gap analysis; both proposed test cases (Vienna, Tennis) were NO-GO on evidence (Part 6)

## Related

- [`prerendered-docs-deploy-verification`](../memory/feedback_prerendered-docs-deploy-verification.md) — merged ≠ live; verify the deployed artifact
- [`worktree-location`](worktree-location.md) — why every worktree path contains `/worktrees/`
- [`data-validation-timeseries`](data-validation-timeseries.md) — content-level validation targets
- [`bash-safety`](bash-safety.md) — tool-choice discipline generally (Part 5 is the same discipline applied to file-editing APIs)
- [`verification-before-completion`](verification-before-completion.md) — "no completion claims without evidence," extended here to structural file integrity, and to platform-capability claims (Part 6)
- [`domain-logic-in-package`](domain-logic-in-package.md) — a different failure mode from the same incident (business logic duplicated outside `R/`)
- [`external-code-zero-trust`](external-code-zero-trust.md) — a plausible external pattern is an idea to evaluate, never an implementation to assume works here (Part 6)
