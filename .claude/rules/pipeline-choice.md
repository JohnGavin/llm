# Pipeline Tool Choice

Path globs: `_targets.R`, `pipeline.R`, `pipeline.nix`, `R/tar_plans/**`

---

## Decision Guide

When creating or modifying analytical pipelines, choose the right tool:

### Use targets (default) when:
- Project has dynamic branching (`tar_map`, `tar_group`)
- Parallel execution needed (`crew` workers)
- Pipeline has 20+ steps
- R-only workflow
- HPC/cloud execution needed
- Project already uses `_targets.R`

### Use rixpress when:
- Hermetic per-step isolation is required (regulatory, audit)
- Pipeline mixes R + Python + Julia natively
- Small pipeline (<20 steps) where reproducibility > performance
- Reproducible Quarto rendering as a pipeline step (`rxp_qmd`)
- CI artifact portability without `targets-runs` branch

### Never mix both in the same project
- A project uses targets OR rixpress, not both
- They manage overlapping concerns (DAG, caching, execution)
- Mixing them creates confusion about which cache is authoritative

## Quick Reference

| Feature | targets | rixpress |
|---|---|---|
| Define steps | `tar_target()` | `rxp_r()` |
| Build | `tar_make()` | `rxp_make()` |
| Read output | `tar_read()` | `rxp_read()` |
| Visualise | `tar_visnetwork()` | `rxp_ggdag()` |
| Config file | `_targets.R` | `pipeline.R` |
| Generated file | `_targets/` dir | `pipeline.nix` |
| Skill | `r-package-workflow` | `rixpress-pipelines` |
