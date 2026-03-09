# Data Engineering with dbt & DuckDB

This skill defines best practices for using **dbt (data build tool)** with **DuckDB** in R/Quarto projects. It focuses on local-first data pipelines, efficient SQL transformations, and leveraging `dbt-duckdb` for orchestration.

## Core Concepts

-   **dbt-duckdb Adapter**: Connects dbt to a local DuckDB file (or in-memory).
-   **ELT (Extract, Load, Transform)**:
    -   **Load**: Raw data (CSV, JSON, Parquet) -> DuckDB (via R or dbt seeds/sources).
    -   **Transform**: SQL models in dbt refine the data.
-   **DuckPlyr**: Using `dplyr` syntax on DuckDB backends for seamless R integration.

## Configuration (`profiles.yml`)

Configure the dbt profile to point to your project's DuckDB database.

```yaml
llm_project:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: 'inst/extdata/analytics.duckdb'  # Persistent DB path
      extensions:
        - parquet
        - httpfs
```

## Workflow Integration

### 1. Project Setup
Initialize dbt within your project (e.g., in a `dbt/` folder).

```bash
dbt init my_project --adapter duckdb
```

### 2. External Sources
Use dbt `sources` to reference data loaded by R (e.g., `ccusage` JSON logs).

```yaml
version: 2
sources:
  - name: raw_telemetry
    tables:
      - name: ccusage_logs
        meta:
          external_location: "read_json_auto('inst/extdata/ccusage_*.json')"
```

### 3. Models (SQL)
Write modular SQL transformations.

```sql
-- models/marts/daily_spend.sql
select
    date_trunc('day', timestamp) as date,
    sum(cost_usd) as total_cost
from {{ source('raw_telemetry', 'ccusage_logs') }}
group by 1
```

### 4. Orchestration
Run dbt as part of your `targets` pipeline or shell scripts.

```r
# R/tar_plans/dbt.R
tar_target(
  dbt_run,
  command = {
    processx::run("dbt", args = c("run", "--profiles-dir", "."))
    "inst/extdata/analytics.duckdb" # Return DB path
  },
  format = "file"
)
```

## Best Practices

1.  **Version Control**: Commit `dbt_project.yml` and models. Ignore `dbt_packages/` and `target/`.
2.  **Performance**: Use `materialized='view'` for lightweight models, `table` for heavy aggregations.
3.  **DuckPlyr**: Use `duckplyr` in R for ad-hoc analysis of dbt-produced tables.
    ```r
    library(duckplyr)
    con <- dbConnect(duckdb(), "inst/extdata/analytics.duckdb")
    df <- tbl(con, "daily_spend") |> collect()
    ```

## References
-   [dbt-duckdb Adapter](https://github.com/jwills/dbt-duckdb)
-   [DuckDB R Client](https://duckdb.org/docs/stable/clients/r)
-   [DuckPlyr](https://duckdb.org/2024/04/02/duckplyr)
