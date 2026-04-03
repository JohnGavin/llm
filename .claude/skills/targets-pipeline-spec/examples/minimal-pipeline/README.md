# Minimal Targets Pipeline Example

Demonstrates the modular plan pattern from the targets-pipeline-spec skill.

## Structure

```
_targets.R          # Orchestrator — sources R/, combines plans
R/
  plan_data.R       # Data acquisition (raw_* prefix)
  plan_analysis.R   # Analysis (result_* prefix)
```

## Run

```bash
cd examples/minimal-pipeline
Rscript -e 'targets::tar_make()'
```

## Verify

```bash
Rscript -e 'write.csv(targets::tar_manifest()[, c("name","command","pattern")], "actual_manifest.csv", row.names = FALSE)'
diff output/manifest.csv actual_manifest.csv
```

Expected: 3 targets (`raw_data`, `result_summary`, `result_model`), each in its own plan file, following the naming convention.

## Key Patterns Demonstrated

- `tar_source("R/")` sources all plan files
- Plan functions return `list(tar_target(...))`
- Target prefixes: `raw_*` for data, `result_*` for analysis
- `packages = c("dplyr")` declared per-target
