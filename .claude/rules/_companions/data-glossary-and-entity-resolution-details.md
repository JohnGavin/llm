# Companion: Data Glossary and Entity Resolution — Worked Examples

Worked code examples split out of the always-loaded
[`data-glossary-and-entity-resolution`](../data-glossary-and-entity-resolution.md)
rule to keep it lean. The normative content (When This Applies, CRITICAL
statement, The Pattern's four numbered steps, Forbidden Patterns table)
stays in the rule; this file is the verbatim YAML/R/SQL examples, loaded on
demand.

## Glossary file — worked `data/glossary.yaml` example

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

## Entity-resolution map — worked `data/entity_resolution.yaml` example

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

## Load both as pipeline inputs — worked `_targets.R` fragment

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

## Example 1 — roborev cross-repo joins (R / targets)

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

## Example 2 — severity mapping in DuckDB SQL

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
