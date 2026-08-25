# test-hook-liveness-classification.R
#
# llm#1017 — the overnight report's hook-liveness section claimed 21 hooks had
# "never fired", including session_init and session_stop, both of which had
# fired that same day. It was not measuring execution. It was measuring
# whether a hook calls hook_event_emit.sh, and reporting the difference as
# death.
#
# These tests pin the distinction the fix introduces:
#
#   instrumented=no   →  liveness is UNOBSERVABLE. Never "0 fires".
#   cadence=on-block  →  0 fires is the HEALTHY value.
#   instrumented=yes
#     + every-call
#     + 0 fires       →  the only genuine alert.
#
# The function is sourced out of the sender script rather than re-implemented,
# so a change to the sender that breaks classification fails here.

library(testthat)

.hook_classifier <- local({
  src <- system.file(
    "scripts/send_overnight_self_review_email.R",
    package  = "llm",
    mustWork = FALSE
  )
  if (!nzchar(src) || !file.exists(src)) {
    root <- tryCatch(pkgload::pkg_path(), error = function(e) NULL)
    if (!is.null(root)) {
      src <- file.path(root, ".claude", "scripts", "send_overnight_self_review_email.R")
    }
  }
  src
})

# Extract just classify_hook_liveness() rather than sourcing the whole script,
# which connects to DuckDB and builds an email on load.
.load_classifier <- function() {
  skip_if_not(
    nzchar(.hook_classifier) && file.exists(.hook_classifier),
    "sender script not found"
  )
  exprs <- parse(.hook_classifier)
  env <- new.env(parent = globalenv())
  found <- FALSE
  for (e in exprs) {
    if (is.call(e) && length(e) >= 3L &&
        identical(as.character(e[[1]]), "<-") &&
        identical(as.character(e[[2]]), "classify_hook_liveness")) {
      eval(e, envir = env)
      found <- TRUE
      break
    }
  }
  skip_if_not(found, "classify_hook_liveness() not found in sender script")
  env$classify_hook_liveness
}

.hooks_dir <- local({
  root <- tryCatch(pkgload::pkg_path(), error = function(e) NULL)
  if (is.null(root)) "" else file.path(root, ".claude", "hooks")
})

test_that("a hook with no emitter call is unobservable, not zero", {
  f <- .load_classifier()
  d <- withr::local_tempdir()
  writeLines(c("#!/usr/bin/env bash", "echo hello"), file.path(d, "plainhook.sh"))

  r <- f("plainhook", d)
  expect_identical(r$instrumented, "no")
  # This is the whole point: "no" must be distinguishable from "yes + 0 fires".
  expect_false(identical(r$instrumented, "yes"))
})

test_that("an emitter call in a COMMENT does not count as instrumentation", {
  f <- .load_classifier()
  d <- withr::local_tempdir()
  # Every guard documents hook_event_emit.sh in its header. Counting those
  # mentions would mark uninstrumented hooks as instrumented and put them back
  # in the alerting population — the bug in the opposite direction.
  writeLines(
    c("#!/usr/bin/env bash",
      "# see hook_event_emit.sh for the spool rationale",
      "echo hello"),
    file.path(d, "commented.sh")
  )
  expect_identical(f("commented", d)$instrumented, "no")
})

test_that("a real emitter call is detected", {
  f <- .load_classifier()
  d <- withr::local_tempdir()
  writeLines(
    c("#!/usr/bin/env bash",
      "_emit_hook_event \"PreToolUse:blocked\" \"x\""),
    file.path(d, "guard.sh")
  )
  expect_identical(f("guard", d)$instrumented, "yes")
})

test_that("cadence is read from the hook's own declaration", {
  f <- .load_classifier()
  d <- withr::local_tempdir()

  writeLines(
    c("#!/usr/bin/env bash",
      "# hook-liveness: on-block",
      "_emit_hook_event \"PreToolUse:blocked\" \"x\""),
    file.path(d, "blocker.sh")
  )
  expect_identical(f("blocker", d)$cadence, "on-block")

  writeLines(
    c("#!/usr/bin/env bash",
      "# hook-liveness: every-call",
      "_emit_hook_event \"PreToolUse\" \"x\""),
    file.path(d, "probe.sh")
  )
  expect_identical(f("probe", d)$cadence, "every-call")
})

test_that("a missing cadence declaration defaults to unknown, not on-block", {
  f <- .load_classifier()
  d <- withr::local_tempdir()
  writeLines(
    c("#!/usr/bin/env bash",
      "_emit_hook_event \"PreToolUse:blocked\" \"x\""),
    file.path(d, "undeclared.sh")
  )
  # Defaulting to on-block would silence a genuinely dead hook that simply
  # forgot its marker. Unknown is treated as every-call by the caller, i.e.
  # it still alerts.
  expect_identical(f("undeclared", d)$cadence, "unknown")
  expect_false(identical(f("undeclared", d)$cadence, "on-block"))
})

test_that("an unreadable script is unknown, never 'no'", {
  f <- .load_classifier()
  d <- withr::local_tempdir()
  # No file at all: we cannot say whether it is instrumented, and saying "no"
  # would assert a fact we do not have. checks-must-distinguish-unknown.
  r <- f("does_not_exist", d)
  expect_identical(r$instrumented, "unknown")
  expect_identical(r$cadence, "unknown")
})

test_that("the real hooks tree classifies as expected (llm#1017 evidence)", {
  skip_if_not(nzchar(.hooks_dir) && dir.exists(.hooks_dir), "hooks dir not found")
  f <- .load_classifier()

  # The two hooks named in the issue. Both demonstrably run every session;
  # neither calls the emitter. They must never be reported as silent.
  for (h in c("session_init", "session_stop")) {
    skip_if_not(file.exists(file.path(.hooks_dir, paste0(h, ".sh"))),
                paste0(h, ".sh not present"))
    expect_identical(f(h, .hooks_dir)$instrumented, "no",
                     info = paste(h, "must be classified unobservable"))
  }

  # The control: a hook that IS instrumented, and is declared on-block. If
  # this came back "no", the detection would be broken in a way that made
  # every hook look unobservable and the section vacuously quiet.
  skip_if_not(file.exists(file.path(.hooks_dir, "secret_leak_guard.sh")))
  slg <- f("secret_leak_guard", .hooks_dir)
  expect_identical(slg$instrumented, "yes")
  expect_identical(slg$cadence, "on-block")

  # And one declared every-call, so both cadence branches are exercised
  # against real files rather than fixtures only.
  skip_if_not(file.exists(file.path(.hooks_dir, "tool_input_probe.sh")))
  expect_identical(f("tool_input_probe", .hooks_dir)$cadence, "every-call")
})

test_that("every instrumented hook in the tree declares a cadence", {
  skip_if_not(nzchar(.hooks_dir) && dir.exists(.hooks_dir), "hooks dir not found")
  f <- .load_classifier()

  hooks <- sub("\\.sh$", "", basename(list.files(.hooks_dir, pattern = "\\.sh$")))
  cls <- lapply(hooks, f, hooks_dir = .hooks_dir)
  instr <- vapply(cls, function(x) x$instrumented, character(1))
  cad   <- vapply(cls, function(x) x$cadence,      character(1))

  # Undeclared is not an error — it alerts, which is safe — but a new
  # instrumented hook that forgets its marker will be reported as silent
  # forever. Fail here instead, where the message says what to add.
  missing <- hooks[instr == "yes" & cad == "unknown"]
  expect_identical(
    missing, character(0),
    info = paste0(
      "instrumented hooks missing a '# hook-liveness: on-block|every-call' ",
      "declaration: ", paste(missing, collapse = ", ")
    )
  )
})

# ── derive_registered_hooks(): emitted name vs script basename ──────────────
#
# Second-order defect found by rendering the fixed section rather than by
# reading it. tool_input_probe.sh is registered twice —
#   ~/.claude/hooks/tool_input_probe.sh artifact_probe
#   ~/.claude/hooks/tool_input_probe.sh webfetch_probe
# — and emits under that ARGUMENT, not its own basename. Matching on the
# basename found no rows and reported a hook that fires constantly as SILENT,
# while its rows sat in the table under two other names.

.load_deriver <- function() {
  skip_if_not(
    nzchar(.hook_classifier) && file.exists(.hook_classifier),
    "sender script not found"
  )
  exprs <- parse(.hook_classifier)
  env <- new.env(parent = globalenv())
  found <- FALSE
  for (e in exprs) {
    if (is.call(e) && length(e) >= 3L &&
        identical(as.character(e[[1]]), "<-") &&
        identical(as.character(e[[2]]), "derive_registered_hooks")) {
      eval(e, envir = env)
      found <- TRUE
      break
    }
  }
  skip_if_not(found, "derive_registered_hooks() not found")
  env$derive_registered_hooks
}

.write_settings <- function(dir, commands) {
  cfg <- list(hooks = list(PreToolUse = list(list(
    matcher = "*",
    hooks = lapply(commands, function(cm) list(type = "command", command = cm))
  ))))
  f <- file.path(dir, "settings.json")
  writeLines(jsonlite::toJSON(cfg, auto_unbox = TRUE, pretty = TRUE), f)
  f
}

test_that("a hook's emitted name comes from its argument, not its basename", {
  f <- .load_deriver()
  d <- withr::local_tempdir()
  sp <- .write_settings(d, c(
    "~/.claude/hooks/tool_input_probe.sh artifact_probe",
    "~/.claude/hooks/tool_input_probe.sh webfetch_probe"
  ))
  r <- f(sp)

  # Two registrations of one script, under the two names it actually emits.
  expect_setequal(r$hook_name, c("artifact_probe", "webfetch_probe"))
  # …but classification must still read the one script that backs them both.
  expect_identical(unique(r$script), "tool_input_probe")
})

test_that("a hook with no argument keeps its basename as the emitted name", {
  f <- .load_deriver()
  d <- withr::local_tempdir()
  sp <- .write_settings(d, "~/.claude/hooks/compound_command_guard.sh")
  r <- f(sp)
  expect_identical(r$hook_name, "compound_command_guard")
  expect_identical(r$script,    "compound_command_guard")
})

test_that("log_session.sh only counts as an emitter for its `hook` subcommand", {
  f <- .load_classifier()
  d <- withr::local_tempdir()

  # `hook` writes hook_events. This is context_monitor's path, and it is the
  # single most active producer in the table.
  writeLines(
    c("#!/usr/bin/env bash",
      "_log_script=\"$HOME/.claude/scripts/log_session.sh\"",
      "\"$_log_script\" hook \"$_sid\" proj ctx name PostToolUse"),
    file.path(d, "emits.sh")
  )
  expect_identical(f("emits", d)$instrumented, "yes")

  # start/stop/agent_* write sessions and agent_runs, NOT hook_events. Counting
  # them put session_init and session_stop back in the SILENT column — the
  # original bug re-created by its own fix. Caught by re-rendering the report,
  # not by reasoning about it.
  for (sub in c("start", "stop", "agent_start", "agent_stop")) {
    writeLines(
      c("#!/usr/bin/env bash",
        "_log_script=\"$CLAUDE_DIR/scripts/log_session.sh\"",
        paste0("\"$_log_script\" ", sub, " \"$_sid\" proj")),
      file.path(d, "other.sh")
    )
    expect_identical(f("other", d)$instrumented, "no",
                     info = paste("log_session.sh", sub, "does not write hook_events"))
  }
})
