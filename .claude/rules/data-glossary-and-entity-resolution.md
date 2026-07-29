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

## Worked Examples

See [`_companions/data-glossary-and-entity-resolution-details.md`](_companions/data-glossary-and-entity-resolution-details.md)
for the full worked examples: roborev cross-repo joins (R / targets) and
severity mapping in DuckDB SQL. The normative rule above is complete without it.

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
- JohnGavin/llm#474 — origin issue
- JohnGavin/llm#471 — cross-repo severity comparison (canonical repo_id required)
- JohnGavin/llm#470 — goodpractice custom check (future: verifies glossary
  covers every distinct value in configured join columns)
