---
paths:
  - "R/**"
  - "shiny/**"
  - "_targets.R"
  - "R/tar_plans/**"
---
# Module Isolation Rules

## Layers

Each R source file belongs to exactly one layer (see @family tags).
Allowed cross-layer dependencies are defined in plan_dag_validation.R.

| Layer | Files | @family tag |
|---|---|---|
| data-acquisition | 01_data_acquisition.R, data_access.R | data-acquisition |
| data-cleaning | data_cleaning.R | data-cleaning |
| data-dictionary | data_dictionary.R | data-dictionary |
| cytogenetics | 01b_cytogenetic_data.R, 08_cytogenetic_viz.R | cytogenetics |
| quality-control | 02_quality_control.R | quality-control |
| differential-expression | 03_differential_expression.R, 06_de_visualization.R | differential-expression |
| survival | 04_survival_analysis.R, 09_survival_viz.R | survival |
| pathway | 05_pathway_analysis.R, 07_gene_annotation.R | pathway |
| storage | database_parquet.R | storage |
| api | 10_api.R | api |
| utilities | utils.R | utilities |

## Shiny: :: discipline

- NEVER use `library(coMMpass)` in shiny/ code
- Always use `coMMpass::function_name()` for explicit imports
- Custom lint in R/dev/lint_shiny_imports.R enforces this

## Documentation: @family tags

- Every @export function MUST have a @family tag
- Family names match the Layer column above
- pkgdown reference index uses `has_concept()` selectors

## Pipeline: DAG validation

- plan_dag_validation checks cross-layer target dependencies
- tar_make() will fail if a plan references targets from a forbidden layer
- Allowed dependencies are defined in the `allowed_deps` list

## API layer: plumber

- All API endpoints live in R/10_api.R and inst/plumber/
- API functions get @family api tags
- API layer may read from any analysis layer but analysis layers
  MUST NOT depend on the API layer
