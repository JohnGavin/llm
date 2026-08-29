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

## Section 5 — Labelled data: `label`/`labels` attributes, factor round-trip, attribute-preservation gotcha

`labelled::var_label()` sets the variable-level description (the `label`
attribute); `labelled::val_labels()` sets the value-level description (the
`labels` attribute, a named vector mapping stored codes to their meaning).
Both build on the `haven_labelled` vector type from the `haven` package.

The two worked examples below are verified against **`haven`**, which is
already a project dependency (`labelled` is not yet in `default.R` — see the
project note in the parent rule). `haven::labelled()` constructs the same
underlying object that `labelled::var_label<-()`/`val_labels<-()` operate
on, and `haven::as_factor()` is the same round-trip as
`labelled::to_factor()`. Once `labelled` is added to `default.R`, swap in its
friendlier accessor names — the attributes and behaviour are identical.

### Worked example: attach a label and value labels, round-trip to a factor

```r
library(haven)

sev <- c(1, 2, 3, 1, 2)

# haven::labelled() attaches BOTH the variable-level `label` attribute
# and the value-level `labels` attribute in one call
sev <- haven::labelled(
  sev,
  labels = c(low = 1, medium = 2, high = 3),  # `labels` attribute
  label  = "Incident severity code"            # `label` attribute
)

attr(sev, "label")
#> [1] "Incident severity code"

# Round-trip value labels -> factor levels
sev_fct <- haven::as_factor(sev)   # labelled::to_factor(sev) is the equivalent
levels(sev_fct)
#> [1] "low"    "medium" "high"
```

Verified: `haven::as_factor()` on the labelled vector above produces a
factor whose `levels()` are exactly `c("low", "medium", "high")` — the
`labels` attribute becomes the factor's `levels` attribute, with no
information re-typed by hand.

### Worked example: the attribute-preservation gotcha

Base `[` drops attributes on a **plain** R vector that only carries a
`label` attribute (no `haven_labelled` class):

```r
sev_plain <- c(1, 2, 3, 1, 2)
attr(sev_plain, "label") <- "Incident severity code"

sev_sub <- sev_plain[c(1, 3)]
is.null(attr(sev_sub, "label"))
#> [1] TRUE   -- the label attribute is gone
```

A `haven_labelled` vector's attributes and class DO survive base `[`
(verified — `haven_labelled` implements `vctrs` methods for subsetting):

```r
sev_lab <- haven::labelled(
  sev_plain,
  labels = c(low = 1, medium = 2, high = 3),
  label  = "Incident severity code"
)
sev_lab_sub <- sev_lab[c(1, 3)]
!is.null(attr(sev_lab_sub, "label"))
#> [1] TRUE   -- survives
inherits(sev_lab_sub, "haven_labelled")
#> [1] TRUE   -- class also survives
```

But an **arithmetic transform inside `dplyr::mutate()`** silently drops both
the class and the label — this is the gotcha that actually bites in
practice, more than the `[` case, because it looks like ordinary tidy code:

```r
library(dplyr)

df  <- tibble::tibble(id = 1:5, sev = sev_lab)
df2 <- df |> dplyr::mutate(sev = sev * 1)   # any arithmetic has the same effect

is.null(attr(df2$sev, "label"))
#> [1] TRUE    -- label is gone
inherits(df2$sev, "haven_labelled")
#> [1] FALSE   -- class is gone too; sev is now a plain double
```

`dplyr::filter()` and a `dplyr::left_join()` that doesn't touch the labelled
column, by contrast, both preserve the label and the class (verified) — the
danger is specifically in transforms that **construct a new vector**
(arithmetic, `case_when()`, `if_else()` on the labelled column, etc.), not in
row-filtering or joining.

### Validation check: catch a dropped label before it reaches a plot or table

```r
assert_labels_preserved <- function(before, after, cols) {
  dropped <- purrr::keep(cols, function(col) {
    before_label <- attr(before[[col]], "label")
    after_label  <- attr(after[[col]], "label")
    !is.null(before_label) && is.null(after_label)
  })
  if (length(dropped) > 0) {
    cli::cli_abort(c(
      "x" = "Label attribute dropped for column{?s}: {dropped}",
      "i" = "Re-apply the label (e.g. {.code attr(x, \"label\") <- ...}) after this step."
    ))
  }
  invisible(TRUE)
}

# Passes: filter() preserves the label
assert_labels_preserved(df, df |> dplyr::filter(id > 2), "sev")

# Aborts: mutate() arithmetic dropped it
assert_labels_preserved(df, df2, "sev")
#> Error:
#> x Label attribute dropped for column: sev
#> i Re-apply the label (e.g. `attr(x, "label") <- ...`) after this step.
```

Call this after any pipeline step that does arithmetic, type coercion, or a
hand-written `[`-based subset on a labelled column — the two safe verbs
(`filter()`, most joins) don't need it, but there is no general rule for
"which dplyr verb preserves labels", so treat any new transform as
untrusted until checked once.
