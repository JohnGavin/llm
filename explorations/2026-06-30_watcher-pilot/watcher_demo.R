# watcher_demo.R
#
# Pilot test: does watcher detect filesystem changes and invoke callbacks?
# API source: ?watcher (watcher::watcher, watcher R6 class)
#
# Strategy:
# 1. Create a temp dir to watch
# 2. Set up a watcher() with a callback that writes a marker file
# 3. Start the watcher
# 4. Wait 0.5s for the FSEvents monitor to register (macOS requirement)
# 5. Programmatically write a file in the watched dir
# 6. Pump the later event loop (run_now) until marker appears or 10s elapses
# 7. Stop watcher, report outcome
#
# Hard timeout: run via: timeout 30 Rscript watcher_demo.R

library(watcher)
library(later)

cat("watcher version:", as.character(packageVersion("watcher")), "\n")
cat("later version:", as.character(packageVersion("later")), "\n")
cat("Platform:", .Platform$OS.type, Sys.info()[["sysname"]], "\n")

tmp <- tempdir()
watch_dir <- file.path(tmp, paste0("watcher_test_", Sys.getpid()))
dir.create(watch_dir, showWarnings = FALSE)
marker <- file.path(tmp, paste0("marker_", Sys.getpid(), ".txt"))

cat("\nWatch dir:", watch_dir, "\n")
cat("Marker:   ", marker, "\n\n")

callback_paths <- character(0)

w <- watcher(
  path = watch_dir,
  callback = function(paths) {
    callback_paths <<- c(callback_paths, paths)
    cat("[callback] fired at", format(Sys.time(), "%H:%M:%S"), "-",
        length(paths), "path(s):", paste(basename(paths), collapse = ", "), "\n")
    writeLines(
      c(
        paste("fired_at:", format(Sys.time())),
        paste("n_paths:", length(paths)),
        paste("paths:", paste(paths, collapse = "; "))
      ),
      marker
    )
  },
  latency = 0.2  # 200 ms debounce - fast enough for a demo
)

started <- w$start()
cat("watcher$start():", started, "\n")
cat("watcher$is_running():", w$is_running(), "\n")
cat("watcher$get_path():", w$get_path(), "\n")

# Let the FSEvents monitor register before triggering changes
Sys.sleep(0.5)

# Trigger a filesystem event
test_file <- file.path(watch_dir, "trigger.txt")
writeLines(c("test payload", format(Sys.time())), test_file)
cat("\nWrote trigger file:", test_file, "\n")
cat("Polling later event loop (max 10s)...\n")

# Pump the later event loop until callback fires or 10 s elapse
deadline <- proc.time()[3] + 10
callback_fired <- FALSE
repeat {
  later::run_now(0.1)
  if (file.exists(marker)) {
    callback_fired <- TRUE
    break
  }
  if (proc.time()[3] >= deadline) break
  Sys.sleep(0.1)
}

w$stop()
cat("watcher$stop() called. is_running:", w$is_running(), "\n")

cat("\n=== RESULT ===\n")
if (callback_fired) {
  cat("SUCCESS: callback fired after filesystem change.\n")
  cat("Marker file contents:\n")
  writeLines(readLines(marker))
} else {
  cat("FAILURE: callback did not fire within 10 seconds.\n")
  cat("Paths captured:", length(callback_paths), "\n")
}
