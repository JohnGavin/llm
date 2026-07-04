# debrief_step.R — Call 2 of 2
# Purpose: reload the saved profvis object in a FRESH R session and run pv_*
# functions on it. This answers the pilot's key question:
#   "Can pv_* functions operate on a profvis result saved to disk in one
#    Rscript call and re-loaded fresh in a later Rscript call?"
# Run with: timeout 60 Rscript debrief_step.R

library(debrief)

rds_path <- file.path(getwd(), "profile.rds")
cat("Loading profvis object from:", rds_path, "\n")

p <- readRDS(rds_path)
cat("Loaded class:", class(p), "\n")

# --- Key question test: does pv_debrief() work on the reloaded object? ---
cat("\n=== pv_debrief() on reloaded object ===\n")
d <- pv_debrief(p)
cat("pv_debrief() succeeded. Names:\n")
cat(paste(" -", names(d), collapse = "\n"), "\n\n")

cat("total_time_ms:", d$total_time_ms, "\n")
cat("total_samples:", d$total_samples, "\n")
cat("interval_ms:  ", d$interval_ms, "\n")
cat("has_source:   ", d$has_source, "\n\n")

# --- Self time breakdown ---
cat("=== TOP FUNCTIONS BY SELF-TIME ===\n")
print(d$self_time)

cat("\n=== TOP FUNCTIONS BY TOTAL TIME ===\n")
print(d$total_time)

cat("\n=== HOT PATHS ===\n")
print(d$hot_paths)

cat("\n=== SUGGESTIONS ===\n")
print(d$suggestions)

# --- Full text summary ---
cat("\n=== pv_print_debrief() full text output ===\n")
out <- capture.output(pv_print_debrief(p))
cat(out, sep = "\n")

cat("\ndebrief_step.R DONE — pv_* functions WORK on reloaded RDS object.\n")
