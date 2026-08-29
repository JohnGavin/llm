---
paths: ["**/*.qmd", "**/scripts/**/*.R", "**/R/**/*.R", "**/_targets.R"]
---

# Rule: Domain Logic Lives in the Package, Never in a Script

## When This Applies

Writing or reviewing any R code that transforms data — aggregation, merging,
deduplication, a derived business rule — anywhere in an R package project:
`.qmd` dashboards/vignettes, `scripts/*.R`, or `_targets.R` plan files.

## CRITICAL: Scripts Are Consumers, `R/` Is the Only Producer

If the logic is non-trivial enough to get wrong twice, it is non-trivial
enough to need exactly one place to look for "does this already exist."
That place is `R/`. A `.qmd` chunk, a standalone script, or a targets plan
may **call** an exported function from `R/` — it may never **contain** the
transformation itself.

The failure mode this prevents: logic written inline in one script is
invisible to whoever writes the next script. They query the raw data source
directly, re-derive the same domain fact, and often get a subtle part of it
wrong the second time (an aggregation ordering quirk, a weighting step, an
edge case already handled once and now silently unhandled again). The fix
is not "remember to check" — it is removing the place where the mistake can
hide.

## Detection Heuristic

A `dplyr::group_by(...) |> dplyr::summarise(...)` pipeline (or a chain of
roughly 5+ dplyr verbs) appearing **outside** `R/` is the signature of this
mistake. It is precise enough to grep for:

```bash
grep -rn "group_by(" --include="*.qmd" --include="*.R" . \
  | grep -v "^\./R/"
```

Anything this turns up is a candidate for extraction into `R/`, exported,
documented, and tested — with the script rewritten to call it.

## Required Pattern

```r
# WRONG — dashboard.qmd contains the transformation
m <- matches |>
  group_by(session_date) |>
  summarise(shots = sum(shots), .groups = "drop")

# RIGHT — dashboard.qmd calls a package function
m <- merge_same_day_sessions(matches)   # defined once, in R/db.R, tested
```

## Before Writing New Aggregation Code

Grep `R/` for an existing function covering the same domain concept
**before** querying the raw data source and writing new logic:

```bash
ls R/*.R
grep -rln "session\|merge\|aggregate" R/
```

Querying the database directly and writing a fresh `group_by()`/`summarise()`
pipeline is a script-authoring shortcut that skips this check — treat it as
a red flag, not a starting point.

## Origin

`tennis` project, 2026-08-28/29. `merge_same_day_sessions()` logic (SwingVision
splits one practice session into several back-to-back "matches"; merging them
requires summed counts, a recomputed percentage from pooled totals, and
shot-count-weighted speeds computed *before* the shot counts themselves are
summed) was written inline in `dashboard.qmd`. Months later, a second
consumer — an artifact-building script — needed the same session-level view,
queried the database directly, and reintroduced the exact bug the original
implementation had already solved: the two same-day matches were displayed
and charted as separate sessions. The knowledge existed, correctly, in one
file; nothing made it discoverable from anywhere else.

A narrower version of this principle already existed in the
`targets-pipeline-spec` skill (its "❌ Computation in Vignettes" anti-pattern:
`DBI::dbGetQuery()` + `summary()` inline in a vignette chunk), but scoped only
to targets-pipeline projects and phrased as an anti-pattern example rather
than a rule with a detection heuristic. This rule generalizes it.

## Related

- [`targets-pipeline-spec`](../skills/targets-pipeline-spec/SKILL.md) — the
  original, narrower precedent ("❌ Computation in Vignettes")
- [`r-package-workflow`](../skills/r-package-workflow/SKILL.md) — the
  package-first development workflow this rule is a corollary of
- [`data-glossary-and-entity-resolution`](data-glossary-and-entity-resolution.md) —
  same "one canonical place" family, applied to vocabulary instead of logic
- [`portable-build-artifacts`](portable-build-artifacts.md) — a different
  failure mode in the same incident (large-asset file-editing safety)
