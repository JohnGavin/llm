# Recipe: Onboard a New Dataset

## Steps

### 1. Raw data
Place source files in `raw/` or `inst/extdata/`. Document provenance.

### 2. Data dictionary
Create `data/data_dictionary.md` with columns: name, type, description, units, source.

### 3. Validation contract
```r
library(pointblank)
agent <- create_agent(data) |>
  col_is_numeric(columns = c("value")) |>
  col_vals_not_null(columns = c("id", "date")) |>
  col_vals_between(columns = "value", left = 0, right = 1000) |>
  interrogate()
```

### 4. Targets integration
```r
tar_target(raw_data, read_csv(here::here("inst/extdata/data.csv"))),
tar_target(validated_data, validate_data(raw_data)),
```

### 5. Vignette
Create exploratory vignette showing data structure, distributions, quality.

### 6. Verify
- `pointblank::get_agent_report(agent)` — all checks pass
- Data dictionary covers all columns
- Vignette renders without error
