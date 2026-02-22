# rixpress: Hermetic Nix Pipelines

## Description

rixpress builds reproducible analytical pipelines where each step is a
hermetic Nix derivation with content-addressed caching. Use it for
small-to-medium projects that need stronger reproducibility guarantees
than targets provides, or when mixing R/Python/Julia.

**Package:** [docs.ropensci.org/rixpress](https://docs.ropensci.org/rixpress/)

## When to Use rixpress (vs targets)

| Criterion | Use rixpress | Use targets |
|---|---|---|
| Steps need hermetic isolation | Yes | No |
| Polyglot (R + Python/Julia) | Yes | No (reticulate only) |
| Small pipeline (<20 steps) | Yes | Either |
| Dynamic branching needed | No — use targets | Yes |
| crew parallel workers needed | No — use targets | Yes |
| HPC/cloud execution | No — use targets | Yes |
| Large pipeline (50+ targets) | No — use targets | Yes |
| Paper supplement / one-off report | Yes | Either |
| Reproducible Quarto rendering | Yes (rxp_qmd) | Partial |
| CI artifact portability | Yes (export/import) | targets-runs branch |

**Rule of thumb:** If you need `tar_map()`, `tar_group()`, or `crew`,
use targets. If you need hermetic per-step builds or polyglot steps,
use rixpress.

## Quick Start

### 1. Prerequisites

Requires rix and Nix. The project must have `default.nix` (via rix).

```r
# In default.R, add rixpress to r_pkgs
r_pkgs <- c(desc_deps, dev_extras, "rixpress") |> unique() |> sort()
```

### 2. Define Pipeline

Create `pipeline.R` (not `_targets.R`):

```r
library(rixpress)

list(
  rxp_r_file(raw_data, "data/input.csv",
    \(x) read.csv(x)),
  rxp_r(clean_data,
    dplyr::filter(raw_data, !is.na(value))),
  rxp_r(summary_stats,
    dplyr::summarise(clean_data, mean = mean(value), sd = sd(value))),
  rxp_qmd(report, "report.qmd")
) |> rxp_populate()
```

### 3. Build Pipeline

```bash
# rxp_populate() generates pipeline.nix
# Build all steps:
nix-build pipeline.nix

# Or from R:
rxp_make()  # Equivalent
```

### 4. Read Results

```r
rxp_read("summary_stats")
rxp_load()  # Load all outputs into global env
rxp_copy("report", "output/")  # Copy from Nix store
```

### 5. Visualise DAG

```r
rxp_ggdag()        # Static plot
rxp_visnetwork()   # Interactive
```

## Key Functions

| Function | Purpose |
|---|---|
| `rxp_r()` | R computation step |
| `rxp_r_file()` | Read external file into pipeline |
| `rxp_py()`, `rxp_py_file()` | Python steps |
| `rxp_qmd()` | Quarto/Rmd document rendering |
| `rxp_pipeline()` | Group steps into named sub-pipelines |
| `rxp_populate()` | Generate `pipeline.nix` from step list |
| `rxp_make()` | Build the pipeline (calls nix-build) |
| `rxp_read()` | Read a step's output into R |
| `rxp_load()` | Load all outputs into global environment |
| `rxp_copy()` | Copy outputs from Nix store to working dir |
| `rxp_export_artifacts()` | Export build products for CI caching |
| `rxp_import_artifacts()` | Restore cached builds |
| `rxp_ggdag()` | Static DAG visualisation |
| `rxp_visnetwork()` | Interactive DAG visualisation |
| `rxp_trace()` | Inspect pipeline execution |
| `rxp_dag_for_ci()` | Export DAG for CI systems |
| `rxp_py2r()`, `rxp_r2py()` | Cross-language data serialisation |

## How It Differs from targets (Architecture)

**targets:** All steps run in one R process within one Nix shell.
Steps can influence each other via shared global state. Caching is
file-based in `_targets/` store. CI state managed via `targets-runs`
branch.

**rixpress:** Each step is an independent Nix derivation — sandboxed,
no network, no ambient state. Caching is content-addressed in
`/nix/store/` (hash of inputs + complete dependency graph). Identical
inputs always produce identical outputs. CI artifacts portable via
`rxp_export_artifacts()`.

## Polyglot Example (R + Python)

```r
list(
  rxp_r(data, mtcars |> dplyr::select(mpg, wt, hp)),
  rxp_r2py(data_py, data),  # Serialise R → Python
  rxp_py(model, "
    import sklearn.linear_model as lm
    model = lm.LinearRegression()
    model.fit(data_py[['wt', 'hp']], data_py['mpg'])
    result = {'coef': model.coef_.tolist(), 'r2': model.score(data_py[['wt', 'hp']], data_py['mpg'])}
  "),
  rxp_py2r(model_r, model),  # Serialise Python → R
  rxp_qmd(report, "analysis.qmd")
) |> rxp_populate()
```

## CI Integration

### Export/Import Pattern (Alternative to targets-runs Branch)

```yaml
# In .github/workflows/pipeline.yml
- name: Restore cached artifacts
  uses: actions/cache@v4
  with:
    path: .rixpress-artifacts/
    key: rixpress-${{ hashFiles('pipeline.nix') }}

- name: Import artifacts
  run: nix-shell default.nix --run "Rscript -e 'rixpress::rxp_import_artifacts()'"

- name: Build pipeline
  run: nix-shell default.nix --run "Rscript -e 'rixpress::rxp_make()'"

- name: Export artifacts
  run: nix-shell default.nix --run "Rscript -e 'rixpress::rxp_export_artifacts()'"
```

## Sub-Pipelines for Large Projects

```r
list(
  rxp_pipeline("data_prep",
    rxp_r_file(raw, "data/raw.csv", read.csv),
    rxp_r(clean, dplyr::filter(raw, valid == TRUE))
  ),
  rxp_pipeline("analysis",
    rxp_r(model, lm(y ~ x, data = clean)),
    rxp_r(predictions, predict(model))
  ),
  rxp_pipeline("reporting",
    rxp_qmd(report, "report.qmd")
  )
) |> rxp_populate()
```

## What rixpress Does NOT Do

- No dynamic branching (use targets)
- No parallel workers/crew (use targets + crew)
- No HPC/cloud/distributed execution (use targets + crew.cluster)
- No streaming or high-frequency pipelines
- No alternative storage backends beyond Nix store
- Not suited for 50+ step pipelines (use targets)

## Files Created

```
project/
├── pipeline.R         # Pipeline definition (you write this)
├── pipeline.nix       # Generated by rxp_populate() (DO NOT EDIT)
├── default.nix        # Environment (from rix, as usual)
└── .rixpress-artifacts/  # Export/import cache (gitignore this)
```

Add to `.gitignore`:
```
.rixpress-artifacts/
```

Add to `.Rbuildignore`:
```
^pipeline\.R$
^pipeline\.nix$
^\.rixpress-artifacts$
```

## Reference

- [rixpress docs](https://docs.ropensci.org/rixpress/)
- [rix paper, rixpress section](https://b-rodrigues.github.io/rix_paper/#sec-rixpress)
- [GitHub: ropensci/rixpress](https://github.com/ropensci/rixpress)
