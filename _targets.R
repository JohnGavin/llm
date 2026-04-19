# _targets.R - Pipeline orchestrator for llm package
# Modular plans sourced from R/tar_plans/

library(targets)
library(tarchetypes)

# Source all plan files
tar_source("R/tar_plans/")

# Combine all plans
list(
  plan_structure,
  tar_llm_usage(),
  plan_vignette_outputs(),
  plan_vignette_closeread(),
  plan_predictions(),  # Cross-project prediction calibration
  plan_pkgctx(),       # ctx.yaml cache audit + refresh
  plan_pkgdown()       # pkgdown site build + stage docs/
)
