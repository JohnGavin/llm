#!/usr/bin/env Rscript
# Display LLM usage progress bars
# Run this script to see current usage against limits
#
# Usage:
#   Rscript R/scripts/show_usage_progress.R
#   # Or set custom limits:
#   LLM_DAILY_LIMIT=50 LLM_WEEKLY_LIMIT=200 Rscript R/scripts/show_usage_progress.R

# Load required packages
suppressPackageStartupMessages({
  library(cli)
  library(dplyr)
})

# Source the ccusage functions
source(here::here("R/ccusage.R"))

# Display the dashboard
show_usage_dashboard()

# Add a timestamp
cli::cli_text("")
cli::cli_text("{.dim Last updated: {Sys.time()}}")