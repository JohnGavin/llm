#!/usr/bin/env Rscript
# refresh_costs_from_jsonl.R — Upsert daily costs into unified.duckdb
# Usage: Rscript refresh_costs_from_jsonl.R
#
# Source: cmonitor-rs --view daily --output json (already deduped, no double-count).
# Primary dashboard metric is Max20 window utilisation ($140/5h cap),
# calculated at query time from these base costs.

t0 <- proc.time()
suppressPackageStartupMessages({ library(DBI); library(duckdb); library(jsonlite) })

CMONITOR  <- "/Users/johngavin/.cargo/bin/cmonitor-rs"
DB_PATH   <- path.expand("~/.claude/logs/unified.duckdb")

# ---- Fetch daily JSON from cmonitor-rs ---------------------------------------

raw_json <- system2(CMONITOR,
  args   = c("--plan", "max20", "--view", "daily", "--output", "json", "--since", "90d"),
  stdout = TRUE, stderr = FALSE)

combined <- paste(raw_json, collapse = "\n")
data <- fromJSON(combined, simplifyVector = FALSE)
blocks <- data$blocks
if (is.null(blocks)) stop("cmonitor-rs JSON has no 'blocks' field")

# ---- Parse each daily block --------------------------------------------------

parse_block <- function(b) {
  if (isTRUE(b$is_gap)) return(NULL)

  # start_time: [year, day_of_year, hour, min, sec, ...]
  st   <- b$start_time
  date <- as.Date(st[[2]] - 1L, origin = paste0(st[[1]], "-01-01"))

  # model_stats is a list of {model, cost_usd, ...}
  opus <- sonnet <- haiku <- 0
  for (ms in b$model_stats) {
    m <- tolower(ms$model)
    cost <- as.numeric(ms$cost_usd)
    if (grepl("opus",  m)) opus   <- opus   + cost
    else if (grepl("haiku", m)) haiku  <- haiku  + cost
    else                        sonnet <- sonnet + cost
  }
  data.frame(date = date, opus = opus, sonnet = sonnet, haiku = haiku,
             stringsAsFactors = FALSE)
}

rows <- Filter(Negate(is.null), lapply(blocks, parse_block))
if (length(rows) == 0L) stop("cmonitor-rs returned no usable blocks")
wide <- do.call(rbind, rows)

# Aggregate in case multiple blocks share a date
wide <- aggregate(cbind(opus, sonnet, haiku) ~ date, data = wide, FUN = sum)
wide$total <- wide$opus + wide$sonnet + wide$haiku
wide$opus_pct   <- ifelse(wide$total > 0, round(wide$opus   / wide$total * 100, 1), NA_real_)
wide$sonnet_pct <- ifelse(wide$total > 0, round(wide$sonnet / wide$total * 100, 1), NA_real_)
wide$haiku_pct  <- ifelse(wide$total > 0, round(wide$haiku  / wide$total * 100, 1), NA_real_)
wide <- wide[order(wide$date, decreasing = TRUE), ]

cat(sprintf("Parsed %d daily blocks from cmonitor-rs\n", nrow(wide)))

# ---- Upsert into costs table -------------------------------------------------

con <- dbConnect(duckdb(), path = DB_PATH)
on.exit(dbDisconnect(con, shutdown = TRUE))

invisible(dbExecute(con, "
  CREATE TABLE IF NOT EXISTS costs (
    date DATE PRIMARY KEY,
    opus_cost DOUBLE DEFAULT 0, sonnet_cost DOUBLE DEFAULT 0,
    haiku_cost DOUBLE DEFAULT 0, total_cost DOUBLE DEFAULT 0,
    opus_pct DOUBLE, sonnet_pct DOUBLE, haiku_pct DOUBLE
  )
"))

dbWriteTable(con, "costs_staging",
  wide[, c("date", "opus", "sonnet", "haiku", "total",
           "opus_pct", "sonnet_pct", "haiku_pct")],
  overwrite = TRUE)

invisible(dbExecute(con, "
  INSERT INTO costs
    SELECT date,
      opus AS opus_cost, sonnet AS sonnet_cost,
      haiku AS haiku_cost, total AS total_cost,
      opus_pct, sonnet_pct, haiku_pct
    FROM costs_staging
  ON CONFLICT (date) DO UPDATE SET
    opus_cost = excluded.opus_cost, sonnet_cost = excluded.sonnet_cost,
    haiku_cost = excluded.haiku_cost, total_cost = excluded.total_cost,
    opus_pct = excluded.opus_pct, sonnet_pct = excluded.sonnet_pct,
    haiku_pct = excluded.haiku_pct
"))

invisible(dbExecute(con, "DROP TABLE IF EXISTS costs_staging"))

# ---- Summary -----------------------------------------------------------------

elapsed <- (proc.time() - t0)[["elapsed"]]
cat(sprintf("\nUpserted %d dates | Total cost: $%.2f | Elapsed: %.1fs\n",
            nrow(wide), sum(wide$total), elapsed))
cat("\nMost recent 5 dates:\n")
print(head(wide[, c("date", "opus", "sonnet", "haiku", "total")], 5),
      row.names = FALSE)
