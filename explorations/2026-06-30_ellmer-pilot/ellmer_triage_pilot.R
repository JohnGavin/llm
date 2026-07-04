# Pilot: ellmer chat_structured() for GitHub issue triage
#
# Task: classify issue text into {difficulty, area, is_bug}
# This is a JUDGEMENT/CLASSIFICATION task, not data ingestion.
#
# Rule boundary: the "Reproducible Ingestion — NEVER ingest data with the model"
# rule prohibits using LLMs to read/transcribe/aggregate data files. This pilot
# stays on the allowed side: short free-text classification where no ground-truth
# numeric data exists. The model is asked to make a judgement call, not read a
# CSV row and return its value.
#
# Auth: OPENAI_API_KEY must be in the environment (not committed here).
# Model: gpt-4o-mini — cheap, fast, sufficient for structured classification.
#
# 2026-06-30 — fixer agent, dispatch 7735f456

library(ellmer)

# ---- Schema ----
# Define the structured output type we want back from the model.
# type_object() returns a TypeObject that ellmer uses to enforce JSON schema.
issue_triage_type <- type_object(
  "GitHub issue triage result",
  difficulty = type_enum(
    "Difficulty estimate for a contributor",
    values = c("easy", "medium", "hard")
  ),
  area = type_string(
    "Primary area of the codebase affected, e.g. 'CI', 'Nix', 'Shiny', 'targets', 'docs'"
  ),
  is_bug = type_boolean(
    "TRUE if this is a defect report; FALSE if it is a feature request or question"
  )
)

# ---- System prompt ----
system_prompt <- paste(
  "You are a technical triage assistant for an R package project.",
  "Given a GitHub issue title and body, return a structured classification.",
  "Be concise: the fields are difficulty (easy/medium/hard),",
  "area (single short string), is_bug (true/false).",
  "Base difficulty on estimated contributor effort, not user impact."
)

# ---- Sample issues ----
# Two representative issues — no real data ingestion, just triage inputs.
sample_issues <- list(
  list(
    title = "Typo in CHANGELOG.md: 'recieve' should be 'receive'",
    body  = "Line 47 of CHANGELOG.md has a typo."
  ),
  list(
    title = "tar_make() hangs indefinitely when crew workers fail to start",
    body  = paste(
      "Repro: set crew_controller with n_workers=4, run tar_make().",
      "When the nix shell is missing 'furrr', workers fail silently and tar_make() hangs.",
      "No timeout, no error message. Have to kill the R session."
    )
  )
)

# ---- Run triage ----
# A fresh Chat object per issue keeps conversation turns isolated.
# echo=FALSE suppresses streaming to stdout.
results <- lapply(seq_along(sample_issues), function(i) {
  issue <- sample_issues[[i]]
  prompt <- paste0("Title: ", issue$title, "\n\nBody: ", issue$body)

  cat(sprintf("\n--- Issue %d ---\n", i))
  cat("Title:", issue$title, "\n")

  ch <- ellmer::chat_openai(
    system_prompt = system_prompt,
    model         = "gpt-4o-mini",
    echo          = FALSE
  )

  t0     <- proc.time()[["elapsed"]]
  result <- ch$chat_structured(prompt, type = issue_triage_type)
  elapsed <- proc.time()[["elapsed"]] - t0

  cat(sprintf(
    "Result: difficulty=%s | area=%s | is_bug=%s | latency=%.1fs\n",
    result$difficulty, result$area, result$is_bug, elapsed
  ))

  usage <- ch$get_tokens()
  cat(sprintf(
    "Tokens: input=%d output=%d\n",
    usage$input[nrow(usage)],
    usage$output[nrow(usage)]
  ))

  list(
    title   = issue$title,
    result  = result,
    elapsed = elapsed,
    tokens  = usage[nrow(usage), ]
  )
})

cat("\n--- Summary ---\n")
total_in  <- sum(vapply(results, function(r) r$tokens$input,  numeric(1)))
total_out <- sum(vapply(results, function(r) r$tokens$output, numeric(1)))
# gpt-4o-mini pricing (June 2026): $0.15/1M input, $0.60/1M output
cost_usd <- (total_in / 1e6) * 0.15 + (total_out / 1e6) * 0.60
cat(sprintf(
  "Total tokens: %d in / %d out | Estimated cost: $%.5f\n",
  total_in, total_out, cost_usd
))
cat("Verdict: see README.md\n")
