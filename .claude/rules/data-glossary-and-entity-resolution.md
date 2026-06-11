---
description: Every join key has one canonical form — glossary + entity-resolution map applied before any join or aggregation
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
entry per business entity:

```yaml
# data/glossary.yaml
entities:
  repo_id:
    canonical: repo_id
    description: "Unique repository identifier — owner/repo form, lowercase"
    example: "johngavin/llm"
  severity_level:
    canonical: severity_level
    description: "Roborev finding severity: critical | major | minor | info"
    values: [critical, major, minor, info]
  account_name:
    canonical: account_name
    description: "Canonical account name (ALLCAPS short form)"
    example: "ACME"
```

### 2. Entity-resolution map (alias → canonical)

Create `data/entity_resolution.yaml`:

```yaml
# data/entity_resolution.yaml
# format: alias: canonical_value
repo_id:
  - alias: "JohnGavin/llm"
    canonical: "johngavin/llm"
  - alias: "johngavin/LLM"
    canonical: "johngavin/llm"
severity_level:
  - alias: "sev"
    canonical: "severity_level"
  - alias: "HIGH"
    canonical: "critical"
  - alias: "high"
    canonical: "critical"
  - alias: "MEDIUM"
    canonical: "major"
account_name:
  - alias: "Acme Corp"
    canonical: "ACME"
  - alias: "Acme Corporation"
    canonical: "ACME"
  - alias: "ACME-NA"
    canonical: "ACME"
```

### 3. Load both as pipeline inputs (R / targets)

`load_entity_resolution()` reads the YAML and flattens it to a long tibble
(`entity`, `alias`, `canonical`). `resolve_entity(values, entity, tbl)` looks
up each value and `cli::cli_abort()` on any unmapped alias.

Expose both as `targets` inputs so downstream targets rebuild on glossary
changes:

```r
# _targets.R (fragment)
tar_target(glossary,         load_glossary()),
tar_target(entity_resolution, load_entity_resolution()),
tar_target(findings_normalised, {
  findings_raw |>
    dplyr::mutate(
      repo_id        = resolve_entity(repo, "repo_id", entity_resolution),
      severity_level = resolve_entity(severity, "severity_level", entity_resolution)
    )
}),
```

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

### Example 1 — roborev cross-repo joins (R / targets)

```r
# Context: roborev DB uses "johngavin/llm"; GitHub API returns "JohnGavin/llm"

# WRONG — silent mismatch; zero rows joined
findings |> dplyr::left_join(commits, by = c("repo" = "repo_name"))

# RIGHT — resolve both sides to canonical before joining
findings_norm <- findings |>
  dplyr::mutate(repo_id = resolve_entity(repo, "repo_id", entity_resolution))
commits_norm  <- commits  |>
  dplyr::mutate(repo_id = resolve_entity(repo_name, "repo_id", entity_resolution))
findings_norm |> dplyr::left_join(commits_norm, by = "repo_id")
```

### Example 2 — severity mapping in DuckDB SQL

```sql
-- WRONG: ad-hoc CASE WHEN, not in the glossary
SELECT CASE
  WHEN sev = 'HIGH' THEN 'critical'
  WHEN sev = 'MEDIUM' THEN 'major'
  ELSE sev
END AS severity_level
FROM findings;

-- RIGHT: load entity_resolution as a reference table, then join
-- (materialise resolution_tbl from data/entity_resolution.yaml via R before this query)
SELECT f.*, r.canonical AS severity_level
FROM findings f
LEFT JOIN resolution_tbl r
  ON r.entity = 'severity_level' AND r.alias = f.sev;
-- Follow with a validation query: any unmatched sev values should error
```

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
