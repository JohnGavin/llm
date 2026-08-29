---
description: Every join key has one canonical form — glossary + entity-resolution map applied before any join or aggregation
paths:
  - "data/**"
  - "**/*.sql"
  - "_targets.R"
  - "R/tar_plans/**"
---

# Rule: Data Glossary and Entity Resolution (Mandatory)

## When This Applies

Every project that joins data from two or more sources where the join key has
more than one human form. Examples:

- `user_id` vs `email` vs `username` — three forms for one identity concept
- `repo` vs `repo_full_name` vs `slug` vs `project` — same repository, four names
- `severity` vs `sev` vs `severity_level` — roborev DB vs GitHub labels vs internal config
- `"Acme Corp"` vs `"Acme Corporation"` vs `"ACME-NA"` — three strings for one account

If your code has a raw string join condition, a CASE WHEN map, or a manually
maintained `left_join(by = c("col_a" = "col_b"))` with no backing source of
truth, this rule applies.

## Source

JohnGavin/llm#474 — Salesforce 8 Design Principles gap analysis (Principle 2:
Harmonise data with metadata-driven understanding). Concrete trigger: the
roborev daily report joined `findings` (roborev DB) with `commits` (GitHub)
by repo slug. Slug normalisation differed by source; findings were attributed
to the wrong repo and the cross-repo severity comparison (#471) was
meaningless.

## CRITICAL: Every Join Key Has One Canonical Form

Two systems disagreeing on a name is not a data-quality bug — it is a missing
mapping. The canonical name is the project's authoritative identifier. Every
alias is a deviation that MUST be resolved to the canonical form before any
join, aggregation, or display. The mapping lives in one place; all code reads
from that place.

A join that hard-codes `col_a = "GitHub"` when the DB stores `"github"` is an
untracked alias — invisible until it produces a silent wrong answer.

## The Pattern

### 1. Glossary file (single source of truth for canonical names)

Create `data/glossary.yaml` (or `inst/glossary.yaml` for R packages). One
entry per business entity, each with `canonical:` and `description:` fields.
A worked `data/glossary.yaml` example is in the companion doc.

### 2. Entity-resolution map (alias → canonical)

Create `data/entity_resolution.yaml` mapping each alias to its canonical
value, one block per entity. A worked `data/entity_resolution.yaml` example
is in the companion doc.

### 3. Load both as pipeline inputs (R / targets)

`load_entity_resolution()` reads the YAML and flattens it to a long tibble
(`entity`, `alias`, `canonical`). `resolve_entity(values, entity, tbl)` looks
up each value and `cli::cli_abort()` on any unmapped alias.

Expose both as `targets` inputs so downstream targets rebuild on glossary
changes. A worked `_targets.R` fragment is in the companion doc.

### 4. SQL / DuckDB equivalent (duckplyr)

For SQL-heavy pipelines, materialise the resolution map as a reference table
and join before downstream queries. Follow with a validation query to fail
fast on any unmapped values — see Worked Example 2 below for the full pattern.

### 5. Variable-level descriptions: attach them to the data, don't duplicate them in a doc

Steps 1-4 above cover **join-key** aliasing. A separate but related drift
happens at the **column** level: a human-readable description of what a
variable means ("Incident severity code", "1=low, 2=medium, 3=high") is
usually written once into a glossary document and never touched again, while
the data itself carries no memory of that description. The two fall out of
sync the moment either one changes.

The fix is the same discipline applied one level down: attach the
description to the column itself, as a `label` attribute (what the variable
is) and a `labels` attribute (what its coded values mean), using
`labelled::var_label()` / `labelled::val_labels()` (or the `haven` package,
which the labelled ecosystem builds on). The glossary becomes something
**derived from** the labelled data — e.g. `purrr::map(df, attr, "label")` —
rather than a parallel document that can drift.

```r
library(labelled)

var_label(df$severity)  <- "Incident severity code"
val_labels(df$severity) <- c(low = 1, medium = 2, high = 3)
```

Value labels round-trip to a factor's levels via `labelled::to_factor()`
(equivalent: `haven::as_factor()`, verified below), so the same description
drives both the raw coded column and any factor derived from it.
See the companion doc for a full worked round-trip, the value-labels ↔
factor-levels mapping, and the attribute-preservation gotcha: base `[` on a
plain (non-`haven_labelled`) vector, and arithmetic transforms inside
`dplyr::mutate()`, can both silently **strip** `label`/`labels` — the
companion doc gives a verified demonstration of exactly what survives
(`dplyr::filter()`, a non-transforming `dplyr::left_join()`) and what
doesn't, plus a validation-check pattern to catch the drop.

> **Project note:** `labelled` is not yet a dependency in this project's
> `default.R`/`default.nix` — add it there before running the
> `labelled::`-prefixed calls above. The companion doc's verified examples
> use `haven` (already a project dependency) to demonstrate the identical
> underlying `label`/`labels` attribute mechanics.

Cross-reference: the [`visualization`](visualization.md) rule and
`visualization-detailed` skill document the payoff — ggplot2 (4.0.0+),
`table1`, and `gtsummary` all consume the same `label` attribute for
axis titles and table headers, so a variable labelled once here needs no
further labelling at the plotting or reporting layer.

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---|---|---|
| `dplyr::left_join(by = c("slug" = "project_name"))` with no backing map | Implicit alias; silently wrong when either side adds a new form | Create an `entity_resolution.yaml` entry; join via the resolved canonical column |
| `CASE WHEN repo = 'GitHub' THEN 'github' END` in raw SQL | Ad-hoc, undiscoverable, not reused across queries | Move to entity_resolution.yaml; load as a reference table |
| Canonical name defined in a comment | Not machine-readable; cannot be enforced | Glossary YAML entry with `canonical:` and `description:` fields |
| Two YAML files with overlapping alias lists | Ambiguous mapping; which wins? | One `entity_resolution.yaml` per project; one entry per alias |
| Alias map inside a targets plan (not a separate file) | Rebuild requires editing pipeline code, not data | Separate data file loaded as a target input |
| `tolower()` or `str_to_lower()` as a normalisation substitute | Case-folding misses structural differences (`repo` vs `repo_full_name`) | Explicit alias map |
| `resolve_entity()` called after join (post-hoc) | Wrong answers already computed | Resolve before any join or aggregation |
| Variable description lives only in a hand-maintained glossary doc, never on the column | Glossary and data drift independently; nothing enforces agreement | `labelled::var_label()`/`val_labels()` on the column; derive the glossary from the data |
| `dplyr::mutate(x = x * scale)` (or similar arithmetic) with no check that `x`'s `label`/`labels` survived | Arithmetic on a labelled vector silently produces a plain, unlabelled vector | Re-apply the label after the transform, or run the `assert_labels_preserved()`-style check from the companion doc |

## Worked Examples

See [`_companions/data-glossary-and-entity-resolution-details.md`](_companions/data-glossary-and-entity-resolution-details.md)
for the full worked examples: roborev cross-repo joins (R / targets),
severity mapping in DuckDB SQL, and the Section 5 labelled-data round-trip +
attribute-preservation gotcha. The normative rule above is complete without it.

## Related

- `cross-cutting-rename` — same single-source-of-truth discipline applied to
  user-facing labels; this rule applies it to join keys and entity identifiers
- `dynamic-prose-values` — canonical values in prose must come from the
  glossary, not hardcoded strings
- `data-validation-pointblank` skill — validate that canonical columns contain
  only values in the glossary after entity resolution
- `duckdb-patterns` skill — duckplyr join patterns; pair with this rule to
  ensure joins are canonical-key-based
- `data-in-packages` rule — data packaging convention; glossary.yaml belongs
  in `inst/` for R packages
- `visualization` rule / `visualization-detailed` skill — consumes the same
  `label` attribute for ggplot2/table1/gtsummary auto-titling (JohnGavin/llm#729)
- `eda-workflow` skill — check for existing `label`/`labels` attributes as
  part of Phase 1 data-structure review
- `data-transformation-stack` skill — attribute-preservation caveat when
  piping labelled columns through DuckDB/duckplyr
- JohnGavin/llm#474 — origin issue
- JohnGavin/llm#471 — cross-repo severity comparison (canonical repo_id required)
- JohnGavin/llm#470 — goodpractice custom check (future: verifies glossary
  covers every distinct value in configured join columns)
- JohnGavin/llm#730 — variable/value descriptions as `label`/`labels` attributes (this section)
