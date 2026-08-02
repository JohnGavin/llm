
test_that("cmonitor execution inside nix-shell produces expected output", {
  skip_on_cran()
  skip_if(Sys.info()[["sysname"]] != "Darwin", "cmonitor only available on macOS")

  # Define the command to run cmonitor inside the nix environment
  # We use the same pattern as the automation script
  cmd <- "caffeinate -i ~/docs_gh/llm/default.sh > /dev/null 2>&1 & pid=$!; sleep 10; kill $pid"
  
  # Since we can't easily drive an interactive shell from here, we will test the 
  # specific command structure that the user provided.
  # The user said: "cmonitor is available inside a nix shell, which can be started via caffeinate -i ~/docs_gh/llm/default.sh"
  
  # However, for automation, we usually want `nix-shell --run "command"`.
  # `default.sh` builds the shell. Let's see if we can use `nix-shell` directly if `default.nix` is built.
  
  # Find the repo root robustly
  find_repo_root <- function() {
    curr <- getwd()
    while (curr != "/" && curr != "C:/") {
      if (file.exists(file.path(curr, "default.nix"))) return(curr)
      curr <- dirname(curr)
    }
    return(NULL)
  }
  
  llm_repo <- find_repo_root()
  skip_if(is.null(llm_repo), "Could not find repo root with default.nix")
  
  # Construct the command to run cmonitor inside the shell
  # We use timeout to ensure it doesn't hang
  # We assume default.nix exists and is valid
  
  # We need to verify that we can run `cmonitor --view daily` inside the shell
  # and capture output.
  
  # Note: `default.sh` is an interactive setup script. The actual shell is defined in `default.nix`.
  # The automation script `bin/refresh_and_preserve.sh` uses `nix-shell default.nix --run ...` for the R script.
  # We should use a similar approach for cmonitor.
  
  # Let's try to run cmonitor via nix-shell
  output_file <- tempfile()
  
  # Attempt to run cmonitor daily view
  # We use `command -v cmonitor` first to check if it's in the path inside the shell
  check_cmd <- sprintf(
    "nix-shell '%s/default.nix' --attr shell --run 'timeout 10 cmonitor --view daily' > '%s' 2>&1",
    llm_repo, output_file
  )
  
  # Execute
  result <- system(check_cmd)
  
  # Capture the output for the snapshot
  output_content <- readLines(output_file)

  # Positron terminal sessions wrap nix-shell invocations through
  # ~/.config/positron/nix-terminal-wrapper.sh, which prints a
  # "Setup complete" / "Terminal wrapper: ..." / "RSTUDIO_TERM_EXEC set to
  # execute new shell with Nix environment." preamble before handing off to
  # the real command. Plain nix-shell (e.g. this test run under CI or a
  # bare terminal) has no such preamble, so a snapshot recorded inside
  # Positron does not match one recorded outside it (llm#874). Depending on
  # which shell runs the wrapper's `echo`, the preamble lines arrive either
  # as real newlines or as a single line with literal two-character "\\n"
  # sequences embedded -- normalise both forms to real lines before
  # filtering, so the snapshot is independent of the terminal that produced
  # the raw output.
  output_content <- unlist(strsplit(output_content, "\\n", fixed = TRUE))
  positron_banner_pattern <- paste0(
    "^(Setup complete|Terminal wrapper:.*|",
    "RSTUDIO_TERM_EXEC set to execute new shell with Nix environment\\.)$"
  )
  output_content <- output_content[!grepl(positron_banner_pattern, output_content, perl = TRUE)]
  
  # We expect some output, even if it fails (stderr is captured)
  expect_true(length(output_content) > 0)
  
  # If cmonitor is not installed/configured in the nix shell, it might fail.
  # But the test ensures we are calling it correctly.
  
  # Snapshot the *type* of output (or error) we get to track changes
  # We sanitize timestamps or variable parts if needed
  # For now, let's look at the first few lines
  
  # Sanitize: remove specific paths or dates
  sanitized_output <- gsub("/Users/[^/]+", "/Users/USER", output_content)
  sanitized_output <- gsub("\\d{4}-\\d{2}-\\d{2}", "YYYY-MM-DD", sanitized_output)
  # Strip ANSI escape codes before filtering nix lines
  sanitized_output <- gsub("\033\\[[0-9;]*m", "", sanitized_output)
  # Filter out nix download/unpacking lines that depend on cache state
  sanitized_output <- sanitized_output[!grepl("^(unpacking |copying path |these \\d+ paths|  /nix/store/)", sanitized_output)]
  # Token counts, session limits, and running dollar costs (e.g.
  # "607,208 tokens", "5,514,144,157", "$5,123.38") are LIVE
  # ccusage/cmonitor values that grow continuously and differ on every run
  # -- the same instability class as the Positron banner above, just from
  # data instead of environment. Mask them so the snapshot tracks output
  # *structure* (per the original intent: "Snapshot the type of output ...
  # to track changes"), not the moving-target values. Dollar-cost figures
  # are masked FIRST because they carry a decimal-cents suffix that the
  # comma-integer mask below does not touch.
  sanitized_output <- gsub("\\$[0-9,]+\\.[0-9]{2}", "$N,NNN.NN", sanitized_output)
  sanitized_output <- gsub("[0-9]{1,3}(,[0-9]{3})+", "N,NNN", sanitized_output)
  # Box-drawn table padding (e.g. the Summary panel) was column-aligned for
  # the original digit count of the masked numbers above; after masking,
  # the right border no longer lines up. Collapse runs of 2+ spaces before
  # a box-drawing vertical border so the snapshot does not depend on how
  # many digits the pre-masked number happened to have.
  sanitized_output <- gsub(" {2,}\u2502", " \u2502", sanitized_output)

  expect_snapshot(head(sanitized_output, 10))
  
  unlink(output_file)
})
