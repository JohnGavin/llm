# Evidence Logging Infrastructure

This directory contains telemetry and evidence files for Claude Code sessions.

## File Structure

```
evidence/
├── README.md                    # This file
├── session_log.jsonl            # Session-level action log
├── quality_history.parquet      # Quality gate scores over time
├── verification_log.jsonl       # Verification evidence
└── parallel_execution_log.jsonl # Parallel agent metrics
```

## File Formats

### session_log.jsonl
JSON Lines format - each line is a JSON object:
```json
{"timestamp": "2025-02-14T10:30:00Z", "action": "edit", "tool": "Edit", "agent": null, "model": "opus", "duration_sec": 2.5, "tokens_in": 150, "tokens_out": 50}
```

### quality_history.parquet
Parquet format with columns:
- `timestamp`: POSIXct
- `project`: character (project name)
- `overall_score`: numeric (0-100)
- `gate_level`: character (none/bronze/silver/gold)
- `coverage`: numeric
- `check_score`: numeric
- `doc_score`: numeric
- `defensive_score`: numeric

### verification_log.jsonl
```json
{"timestamp": "2025-02-14T10:30:00Z", "claim": "tests pass", "evidence_type": "command_output", "verdict": "PASS", "evidence_text": "[ FAIL 0 | WARN 0 | SKIP 2 | PASS 47 ]"}
```

## R Functions for Logging

### Log a session action
```r
log_session_action <- function(action, tool = NULL, agent = NULL, model = NULL,
                               duration_sec = NULL, tokens_in = NULL, tokens_out = NULL,
                               log_file = "~/.claude/evidence/session_log.jsonl") {
  entry <- list(
    timestamp = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    action = action,
    tool = tool,
    agent = agent,
    model = model,
    duration_sec = duration_sec,
    tokens_in = tokens_in,
    tokens_out = tokens_out
  )

  # Remove NULL values
  entry <- entry[!sapply(entry, is.null)]

  cat(jsonlite::toJSON(entry, auto_unbox = TRUE), "\n",
      file = log_file, append = TRUE)
}
```

### Log a verification
```r
log_verification <- function(claim, evidence_type, verdict, evidence_text,
                             log_file = "~/.claude/evidence/verification_log.jsonl") {
  entry <- list(
    timestamp = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    claim = claim,
    evidence_type = evidence_type,
    verdict = verdict,
    evidence_text = substr(evidence_text, 1, 500)  # Truncate long output
  )

  cat(jsonlite::toJSON(entry, auto_unbox = TRUE), "\n",
      file = log_file, append = TRUE)
}
```

### Log quality gate result
```r
log_quality_gate <- function(project, result,
                             log_file = "~/.claude/evidence/quality_history.parquet") {
  entry <- tibble::tibble(
    timestamp = Sys.time(),
    project = project,
    overall_score = result$overall_score,
    gate_level = result$gate_level,
    coverage = result$metrics$coverage$score,
    check_score = result$metrics$check$score,
    doc_score = result$metrics$documentation$score,
    defensive_score = result$metrics$defensive$score
  )

  if (file.exists(log_file)) {
    existing <- arrow::read_parquet(log_file)
    combined <- dplyr::bind_rows(existing, entry)
  } else {
    combined <- entry
  }

  arrow::write_parquet(combined, log_file)
}
```

## Reading Evidence

### Recent session actions
```r
read_session_log <- function(log_file = "~/.claude/evidence/session_log.jsonl", n = 100) {
  if (!file.exists(log_file)) return(tibble::tibble())

  lines <- readLines(log_file, n = n)
  purrr::map_dfr(lines, jsonlite::fromJSON)
}
```

### Quality history
```r
read_quality_history <- function(log_file = "~/.claude/evidence/quality_history.parquet") {
  if (!file.exists(log_file)) return(tibble::tibble())
  arrow::read_parquet(log_file)
}
```

## Targets Integration

Add to `R/tar_plans/plan_evidence.R`:

```r
plan_evidence <- list(
  targets::tar_target(
    evidence_session_log,
    read_session_log(),
    cue = targets::tar_cue(mode = "always")
  ),

  targets::tar_target(
    evidence_quality_history,
    read_quality_history()
  ),

  targets::tar_target(
    evidence_summary,
    summarize_evidence(evidence_session_log, evidence_quality_history)
  )
)
```

## Dashboard Integration

The telemetry dashboard (`vignettes/telemetry.qmd`) loads these targets:

```qmd
```{r}
#| echo: false
targets::tar_load(evidence_session_log)
targets::tar_load(evidence_quality_history)
```
```

## Privacy Note

Evidence files may contain:
- Timestamps of Claude Code usage
- Tool and agent invocations
- Quality scores

These files are stored locally and NOT pushed to git by default.
Add to `.gitignore`:
```
.claude/evidence/*.jsonl
.claude/evidence/*.parquet
```
