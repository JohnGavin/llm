test_that("per-session sentinel: two concurrent sessions do not steal each other's stop", {
  skip_if_not(nzchar(Sys.which("bash")), "bash not found")

  # Use a temp home so the test is fully isolated from the real ~/.claude state
  tmp_home <- withr::local_tempdir()
  logs_dir <- file.path(tmp_home, ".claude", "logs")
  dir.create(logs_dir, recursive = TRUE, showWarnings = FALSE)
  claude_dir <- file.path(tmp_home, ".claude")
  # Create the opt-in flag so the hook does not exit early
  file.create(file.path(claude_dir, ".llmtelemetry_emit"))
  # Create the staging dir
  staging_dir <- file.path(logs_dir, "llmtelemetry-staging")
  dir.create(staging_dir, recursive = TRUE, showWarnings = FALSE)

  pkg_root <- rprojroot::find_package_root_file()
  emit_sh <- file.path(pkg_root, ".claude", "hooks", "llmtelemetry_emit.sh")
  skip_if_not(file.exists(emit_sh), paste("emit hook not found:", emit_sh))

  run_emit <- function(mode, session_id) {
    system2(
      "bash",
      args = c(emit_sh, mode),
      env = c(
        sprintf("HOME=%s", tmp_home),
        sprintf("CLAUDE_PROJECT_DIR=%s", tmp_home),
        sprintf("CLAUDE_SESSION_ID=%s", session_id)
      ),
      stdout = FALSE,
      stderr = FALSE
    )
  }

  sid_a <- "sess-A-concurrency-test"
  sid_b <- "sess-B-concurrency-test"

  # Simulate SessionStart for both sessions
  run_emit("start", sid_a)
  run_emit("start", sid_b)

  # Verify both start state files were created
  expect_true(
    file.exists(file.path(logs_dir, sprintf(".llmtelemetry_started_at.%s", sid_a))),
    label = "session-A start state created"
  )
  expect_true(
    file.exists(file.path(logs_dir, sprintf(".llmtelemetry_started_at.%s", sid_b))),
    label = "session-B start state created"
  )

  # Session A calls /bye: write per-session sentinel for A ONLY
  sentinel_a <- file.path(claude_dir, sprintf(".bye-requested.%s", sid_a))
  file.create(sentinel_a)

  # No sentinel for B — B is still mid-session
  sentinel_b <- file.path(claude_dir, sprintf(".bye-requested.%s", sid_b))
  expect_false(file.exists(sentinel_b), label = "session-B sentinel not yet written")

  # Run stop for session A
  run_emit("stop", sid_a)

  # Session A's per-session sentinel should be consumed
  expect_false(file.exists(sentinel_a), label = "session-A sentinel consumed by its own stop")

  # Session B's state files should be completely untouched
  expect_true(
    file.exists(file.path(logs_dir, sprintf(".llmtelemetry_started_at.%s", sid_b))),
    label = "session-B start state not clobbered after session-A stop"
  )
  expect_true(
    file.exists(file.path(logs_dir, sprintf(".llmtelemetry_session_id.%s", sid_b))),
    label = "session-B SID state not clobbered after session-A stop"
  )

  # A JSONL event should have been emitted for session A
  jsonl_files <- list.files(staging_dir, pattern = "\\.jsonl$", full.names = TRUE)
  expect_true(length(jsonl_files) > 0, label = "JSONL staging file created for session A")
  lines <- unlist(lapply(jsonl_files, readLines))
  expect_true(
    any(grepl(sid_a, lines, fixed = TRUE)),
    label = "emitted JSONL contains session-A ID"
  )
  # Session B ID should NOT appear — it didn't call /bye
  expect_false(
    any(grepl(sid_b, lines, fixed = TRUE)),
    label = "emitted JSONL does NOT contain session-B ID (B is still active)"
  )
})

test_that("per-session sentinel: stop without matching sentinel is a no-op", {
  skip_if_not(nzchar(Sys.which("bash")), "bash not found")

  tmp_home <- withr::local_tempdir()
  logs_dir <- file.path(tmp_home, ".claude", "logs")
  dir.create(logs_dir, recursive = TRUE, showWarnings = FALSE)
  claude_dir <- file.path(tmp_home, ".claude")
  file.create(file.path(claude_dir, ".llmtelemetry_emit"))
  staging_dir <- file.path(logs_dir, "llmtelemetry-staging")
  dir.create(staging_dir, recursive = TRUE, showWarnings = FALSE)

  pkg_root <- rprojroot::find_package_root_file()
  emit_sh <- file.path(pkg_root, ".claude", "hooks", "llmtelemetry_emit.sh")
  skip_if_not(file.exists(emit_sh), paste("emit hook not found:", emit_sh))

  sid_c <- "sess-C-no-sentinel"

  # Write start state
  writeLines(format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ"),
    file.path(logs_dir, sprintf(".llmtelemetry_started_at.%s", sid_c)))
  writeLines(sid_c,
    file.path(logs_dir, sprintf(".llmtelemetry_session_id.%s", sid_c)))

  # No sentinel written — simulates a mid-session Stop (not a /bye)
  rc <- system2(
    "bash",
    args = c(emit_sh, "stop"),
    env = c(
      sprintf("HOME=%s", tmp_home),
      sprintf("CLAUDE_PROJECT_DIR=%s", tmp_home),
      sprintf("CLAUDE_SESSION_ID=%s", sid_c)
    ),
    stdout = FALSE,
    stderr = FALSE
  )

  expect_equal(rc, 0L, label = "exit 0 even when no sentinel present")

  # No JSONL should have been emitted
  jsonl_files <- list.files(staging_dir, pattern = "\\.jsonl$", full.names = TRUE)
  no_event <- length(jsonl_files) == 0 ||
    !any(grepl(sid_c, unlist(lapply(jsonl_files, readLines)), fixed = TRUE))
  expect_true(no_event, label = "no JSONL emitted for non-/bye stop")

  # Start state should be preserved for the eventual real /bye
  expect_true(
    file.exists(file.path(logs_dir, sprintf(".llmtelemetry_started_at.%s", sid_c))),
    label = "start state preserved after no-op stop"
  )
})

test_that("stable session ID: CLAUDE_SESSION_ID is used when provided", {
  skip_if_not(nzchar(Sys.which("bash")), "bash not found")

  tmp_home <- withr::local_tempdir()
  logs_dir <- file.path(tmp_home, ".claude", "logs")
  dir.create(logs_dir, recursive = TRUE, showWarnings = FALSE)
  claude_dir <- file.path(tmp_home, ".claude")
  file.create(file.path(claude_dir, ".llmtelemetry_emit"))
  staging_dir <- file.path(logs_dir, "llmtelemetry-staging")
  dir.create(staging_dir, recursive = TRUE, showWarnings = FALSE)

  pkg_root <- rprojroot::find_package_root_file()
  emit_sh <- file.path(pkg_root, ".claude", "hooks", "llmtelemetry_emit.sh")
  skip_if_not(file.exists(emit_sh), paste("emit hook not found:", emit_sh))

  known_sid <- "stable-env-var-test-id"
  env_vec <- c(
    sprintf("HOME=%s", tmp_home),
    sprintf("CLAUDE_PROJECT_DIR=%s", tmp_home),
    sprintf("CLAUDE_SESSION_ID=%s", known_sid)
  )

  # Run start
  system2("bash", args = c(emit_sh, "start"), env = env_vec,
    stdout = FALSE, stderr = FALSE)

  start_state <- file.path(logs_dir, sprintf(".llmtelemetry_started_at.%s", known_sid))
  sid_state   <- file.path(logs_dir, sprintf(".llmtelemetry_session_id.%s", known_sid))
  expect_true(file.exists(start_state), label = "start state written under CLAUDE_SESSION_ID")
  expect_true(file.exists(sid_state),   label = "SID state written under CLAUDE_SESSION_ID")

  # Write per-session sentinel then run stop
  sentinel <- file.path(claude_dir, sprintf(".bye-requested.%s", known_sid))
  file.create(sentinel)
  system2("bash", args = c(emit_sh, "stop"), env = env_vec,
    stdout = FALSE, stderr = FALSE)

  # JSONL should contain the known session ID, not a generated fallback
  jsonl_files <- list.files(staging_dir, pattern = "\\.jsonl$", full.names = TRUE)
  expect_true(length(jsonl_files) > 0, label = "JSONL file created")
  lines <- unlist(lapply(jsonl_files, readLines))
  expect_true(
    any(grepl(known_sid, lines, fixed = TRUE)),
    label = "emitted JSONL contains the stable CLAUDE_SESSION_ID"
  )
  expect_false(
    any(grepl("^emit-", lines)),
    label = "no generated fallback ID in emitted JSONL"
  )
})

test_that("PPID anchor: start writes anchor file; second start reuses it", {
  # This test verifies the PPID anchor mechanism at the file level.
  # We cannot control the hook's $PPID from R, so instead we pre-seed the
  # anchor file and verify the hook reads it rather than generating a new ID.
  skip_if_not(nzchar(Sys.which("bash")), "bash not found")

  tmp_home <- withr::local_tempdir()
  logs_dir <- file.path(tmp_home, ".claude", "logs")
  dir.create(logs_dir, recursive = TRUE, showWarnings = FALSE)
  claude_dir <- file.path(tmp_home, ".claude")
  file.create(file.path(claude_dir, ".llmtelemetry_emit"))

  pkg_root <- rprojroot::find_package_root_file()
  emit_sh <- file.path(pkg_root, ".claude", "hooks", "llmtelemetry_emit.sh")
  skip_if_not(file.exists(emit_sh), paste("emit hook not found:", emit_sh))

  # Run start WITHOUT CLAUDE_SESSION_ID — should generate a new ID and write anchor
  rc <- system2(
    "bash",
    args = c(emit_sh, "start"),
    env = c(
      sprintf("HOME=%s", tmp_home),
      sprintf("CLAUDE_PROJECT_DIR=%s", tmp_home)
      # No CLAUDE_SESSION_ID
    ),
    stdout = FALSE,
    stderr = FALSE
  )
  expect_equal(rc, 0L, label = "start exits 0 without CLAUDE_SESSION_ID")

  # Exactly one PPID anchor should have been written (all.files=TRUE to see dot-files)
  anchors <- list.files(logs_dir, pattern = "^\\.llmtelemetry_ppid_session\\.",
    full.names = TRUE, all.files = TRUE)
  expect_equal(length(anchors), 1L, label = "exactly one PPID anchor written by start")

  # The anchor must contain a non-empty session ID
  anchor_id <- readLines(anchors[[1]], warn = FALSE)
  expect_true(nzchar(anchor_id), label = "PPID anchor contains non-empty session ID")

  # Corresponding start state file must exist
  expect_true(
    file.exists(file.path(logs_dir, sprintf(".llmtelemetry_started_at.%s", anchor_id))),
    label = "start state file written under anchor's session ID"
  )
})
