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
  plan_predictions()  # Cross-project prediction calibration
)
