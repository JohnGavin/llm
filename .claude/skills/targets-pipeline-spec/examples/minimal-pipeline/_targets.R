# Minimal targets pipeline example
# Demonstrates the modular plan pattern from targets-pipeline-spec skill
#
# Run: targets::tar_make()
# Verify: diff output/manifest.csv against targets::tar_manifest()

library(targets)

tar_source("R/")

list(
  plan_data(),
  plan_analysis()
)
