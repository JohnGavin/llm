---
paths:
  - "**/data-raw/**"
  - "**/inst/extdata/**"
  - "**/R/tar_plans/**"
  - "**/_includes/**"
  - "**/_targets.R"
---

# Rule: Portable Build Artifacts

## When This Applies

Any time a build **writes a file that gets committed** — a serialised object
(`.rds`, `.parquet`, `.qs`), a rendered HTML page, a generated config — and that
file is later read by a *different* machine (CI, a colleague, a deploy runner) or
from a *different checkout* (a worktree, a fresh clone).

## CRITICAL: The Checkout That Built It Must Not Leak Into It

A committed artifact is only reproducible if it is **independent of where it was
built**. Two failure modes, both observed in `llm` within 48 hours, both of which
merged green and were only caught days later by a CI render log:

| Leak | What gets baked in | Symptom |
|---|---|---|
| **Absolute paths inside serialised objects** | The builder's filesystem layout | Renders locally, dies in CI |
| **Path filters matched against absolute paths** | The builder's checkout location | Silently produces *empty* output |

The second is far more dangerous: it does not error, it returns nothing.

---

## Part 1: Serialised objects capture absolute paths

`saveRDS()` preserves an object's internals verbatim, **including absolute
filesystem paths the object captured at construction time**. The clearest case is
`htmltools::htmlDependency()`, which every htmlwidget carries — a recorded
`/nix/store/...` path from the exporting machine, absent on any other. The
symptom (`readRDS()` output, the resulting CI error) is in the companion.

### Required pattern — repair at READ time, never by regenerating

Regenerating the artifact does **not** fix this. It only re-acquires whichever
path the *new* exporting machine has, so the defect returns on the next export
from anywhere else.

Repair when the artifact is loaded: for each dependency whose recorded path
is absent on the current machine, re-resolve it via `system.file()` using the
package name and relative path extracted from the stale absolute path
(worked R snippet in the companion). Three properties this must have:

1. **No-op when the path already resolves** — so it changes nothing on the
   machine that wrote the artifact.
2. **Leave `package`-relative dependencies alone** — those are already portable.
3. **Leave unresolvable paths at their original value** — do not blank them.
   A visible failure beats a silently-missing asset.

Same hazard class, worth checking for: fonts resolved to absolute paths, cached
`system.file()` results, `here::here()` values captured into a stored object,
open connections, and `environment()` captured by closures inside the object.

---

## Part 2: Path filters must match RELATIVE to the scan root

An exclusion intended to skip *nested* subtrees must never be matched against the
absolute path, because the **scan root itself** may contain the excluded token.

```r
# WRONG — the scan root can contain the token
files <- files[!grepl("/(archive|worktrees)/", files)]

# RIGHT — only genuinely nested subtrees are dropped
rel   <- fs::path_rel(files, scan_root)
files <- files[!grepl("(^|/)(archive|worktrees)/", rel)]
```

Why it matters here: **every** worktree path contains `/worktrees/` — both
`.claude/worktrees/` (every dispatched agent) and `~/docs_gh/worktrees/` (every
manual worktree, per `worktree-location`). So a target built anywhere except the
main checkout scanned 377 files and kept **zero**.

The result is not an error. It is a well-formed, empty result that flows
downstream and only surfaces somewhere far away — in the observed case, a
`facet_wrap()` call in a vignette that killed the entire site build.

---

## Part 3: Verify artifacts by content, not by existence

Both incidents passed every gate in place at the time:

| Gate | What it checked | Why it missed this |
|---|---|---|
| `qa_no_nulls` | value is not `NULL` | a zero-row tibble is not `NULL` |
| `qa_rds_freshness` | snapshot mtime vs target mtime | never inspects content |
| CI / deploy status | workflow exit code | the data path was not in `on.push.paths` |

**Before committing a regenerated artifact, diff it against the previous
version's content** — row count, category coverage, non-NA share — not just its
existence or timestamp. A regeneration that shrinks an artifact by orders of
magnitude is a defect until proven otherwise:

```r
old <- readRDS(...); new <- <rebuild>
stopifnot(nrow(new) >= 0.5 * nrow(old))   # tune per artifact
```

---

## Part 4: Prefer the canonical checkout for regeneration

Until an exporter is proven location-independent, regenerate committed artifacts
**from the project's main checkout**, not from a worktree. Where that cannot be
guaranteed, have the exporter print the checkout path it ran from, so a
worktree-built artifact is visible in review rather than silent.

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---|---|---|
| `saveRDS()` an htmlwidget and assume it is portable | Absolute asset paths baked in | Repair on read (Part 1) |
| "Just regenerate it" to fix a path error | Re-acquires the new machine's path | Repair on read, not on write |
| `grepl("/token/", absolute_path)` to skip subtrees | Matches the scan root too | Match relative to the root (Part 2) |
| Accepting a regenerated artifact because it is non-NULL | Empty ≠ NULL | Compare content to the prior version (Part 3) |
| Treating "CI green" as "artifact correct" | The data path may not even trigger CI | Verify the deployed artifact |

## Origin

- [llm#883](https://github.com/JohnGavin/llm/issues/883) / [#885](https://github.com/JohnGavin/llm/pull/885) — DT `html_dependency` absolute nix paths; 13 snapshots affected; blocked all publishing for 2 days
- [llm#889](https://github.com/JohnGavin/llm/issues/889) / [#890](https://github.com/JohnGavin/llm/pull/890) — worktree-exclusion regex matched its own scan root; `vig_scrolly_config` regenerated 222 rows → 0 by [#868](https://github.com/JohnGavin/llm/pull/868) and shipped silently

## Related

- [`_companions/portable-build-artifacts-details.md`](_companions/portable-build-artifacts-details.md)
  — worked code for the Part 1 symptom and read-time repair, split out of this rule
- [`prerendered-docs-deploy-verification`](../memory/feedback_prerendered-docs-deploy-verification.md) — merged ≠ live; verify the deployed artifact
- [`worktree-location`](worktree-location.md) — why every worktree path contains `/worktrees/`
- [`data-validation-timeseries`](data-validation-timeseries.md) — content-level validation targets
