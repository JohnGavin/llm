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
    # Use temp file to avoid stdout/stderr issues
    tmp_file <- tempfile(fileext = ".json")
    on.exit(unlink(tmp_file), add = TRUE)

    # Redirect stdout to file, ignore stderr
    exit_code <- system(paste(cmd, ">", shQuote(tmp_file), "2>/dev/null"))

    if (exit_code != 0) {
      stop(sprintf("Command failed with exit code %d", exit_code))
    }

    # Read JSON from file
    json_text <- paste(readLines(tmp_file, warn = FALSE), collapse = "\n")

    # Find the JSON object (skip any non-JSON preamble)
    json_start <- regexpr("\\{", json_text)
    if (json_start > 0) {
      json_text <- substring(json_text, json_start)
    }

    fromJSON(json_text)
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
