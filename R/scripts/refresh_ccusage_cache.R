# Refresh ccusage cache
# Run this script to update the cached JSON files in inst/extdata
#
# Usage (from project root in nix shell):
#   Rscript R/scripts/refresh_ccusage_cache.R
#   # Or
#   R --quiet --no-save -e "source('R/scripts/refresh_ccusage_cache.R')"

library(jsonlite)

cache_dir <- "inst/extdata"
dir.create(cache_dir, recursive = TRUE, showWarnings = FALSE)

# Fetch and cache each type
types <- c("daily", "session", "blocks")

for (type in types) {
  message(sprintf("Fetching %s data...", type))

  cmd <- sprintf("npx ccusage %s --json --instances", type)
  if (type == "blocks") {
    cmd <- paste(cmd, "--breakdown")
  }

  result <- tryCatch({
    output <- system(cmd, intern = TRUE, ignore.stderr = TRUE)
    # Filter out non-JSON lines
    json_lines <- output[grepl("^[{\\[]", output) | grepl("^\\s*[\"{}\\[\\]]", output)]
    if (length(json_lines) == 0) {
      json_lines <- output
    }
    fromJSON(paste(json_lines, collapse = "\n"))
  }, error = function(e) {
    message(sprintf("  Failed to fetch %s: %s", type, e$message))
    NULL
  })

  if (!is.null(result)) {
    cache_file <- file.path(cache_dir, sprintf("ccusage_%s_all.json", type))
    write_json(result, cache_file, pretty = TRUE, auto_unbox = TRUE)
    message(sprintf("  Saved to %s", cache_file))
  }
}

message("\nCache refresh complete!")

# Print summary
if (file.exists(file.path(cache_dir, "ccusage_session_all.json"))) {
  session_data <- fromJSON(file.path(cache_dir, "ccusage_session_all.json"))
  if (!is.null(session_data$totals)) {
    message(sprintf("\nTotal cost: $%.2f", session_data$totals$totalCost))
    message(sprintf("Total tokens: %s", format(session_data$totals$totalTokens, big.mark = ",")))
  }
}
