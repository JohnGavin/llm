#!/usr/bin/env Rscript
# refresh_costs_from_jsonl.R — Upsert JSONL token costs into unified.duckdb
# Usage: Rscript refresh_costs_from_jsonl.R
#
# Costs stored are API-equivalent (pay-as-you-go pricing).
# Primary dashboard metric is Max20 window utilisation ($140/5h cap),
# calculated at query time from these base costs.

t0 <- proc.time()
suppressPackageStartupMessages({ library(DBI); library(duckdb) })

JSONL_GLOB <- path.expand("~/.claude/projects/**/*.jsonl")
DB_PATH    <- path.expand("~/.claude/logs/unified.duckdb")

# Per-1M-token prices (matches cmonitor v3.1.0 / Anthropic API pricing)
# Cache reads are heavily discounted (10% of input price)
PRICING <- list(
  opus   = c(input = 15,   output = 75,   cache_creation = 18.75, cache_read = 1.50),
  sonnet = c(input = 3,    output = 15,   cache_creation = 3.75,  cache_read = 0.30),
  haiku  = c(input = 0.25, output = 1.25, cache_creation = 0.30,  cache_read = 0.03)
)

# ---- Read all JSONL in one DuckDB pass ----------------------------------------

con <- dbConnect(duckdb(), path = DB_PATH)
on.exit(dbDisconnect(con, shutdown = TRUE))

raw <- dbGetQuery(con, sprintf("
  SELECT
    timestamp,
    message.model                             AS model,
    COALESCE(message.usage.input_tokens, 0)                AS input_tokens,
    COALESCE(message.usage.output_tokens, 0)               AS output_tokens,
    COALESCE(message.usage.cache_creation_input_tokens, 0) AS cache_creation_tokens,
    COALESCE(message.usage.cache_read_input_tokens, 0)     AS cache_read_tokens
  FROM read_json_auto('%s', union_by_name = true, ignore_errors = true)
  WHERE type = 'assistant'
    AND message.usage IS NOT NULL
    AND message.model IS NOT NULL
    AND message.model != '<synthetic>'
", JSONL_GLOB))

cat(sprintf("Read %d assistant entries\n", nrow(raw)))

# ---- Compute costs -----------------------------------------------------------

raw$family <- ifelse(grepl("opus",  raw$model, ignore.case = TRUE), "opus",
              ifelse(grepl("haiku", raw$model, ignore.case = TRUE), "haiku", "sonnet"))
raw$date   <- as.Date(substr(raw$timestamp, 1, 10))

raw$cost <- mapply(function(fam, inp, out, cc, cr) {
  p <- PRICING[[fam]]
  (inp * p["input"] + out * p["output"] +
   cc  * p["cache_creation"] + cr * p["cache_read"]) / 1e6
}, raw$family, raw$input_tokens, raw$output_tokens,
   raw$cache_creation_tokens, raw$cache_read_tokens)

# ---- Aggregate and pivot to wide ---------------------------------------------

agg  <- aggregate(cost ~ date + family, data = raw, FUN = sum)
wide <- reshape(agg, idvar = "date", timevar = "family",
                direction = "wide", v.names = "cost")
colnames(wide) <- sub("^cost\\.", "", colnames(wide))

for (fam in c("opus", "sonnet", "haiku")) {
  if (!fam %in% colnames(wide)) wide[[fam]] <- 0
  wide[[fam]][is.na(wide[[fam]])] <- 0
}

wide$total      <- wide$opus + wide$sonnet + wide$haiku
wide$opus_pct   <- ifelse(wide$total > 0, round(wide$opus   / wide$total * 100, 1), NA_real_)
wide$sonnet_pct <- ifelse(wide$total > 0, round(wide$sonnet / wide$total * 100, 1), NA_real_)
wide$haiku_pct  <- ifelse(wide$total > 0, round(wide$haiku  / wide$total * 100, 1), NA_real_)
wide <- wide[order(wide$date, decreasing = TRUE), ]

# ---- Upsert into costs table -------------------------------------------------

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
