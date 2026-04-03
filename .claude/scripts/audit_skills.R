#' Audit all skills for agentskills.io spec compliance
#' Reports: description quality, name validation, gotchas presence, scripts usage
#'
#' Usage: Rscript .claude/scripts/audit_skills.R

skills_dir <- file.path(Sys.getenv("HOME"), ".claude/skills")
dirs <- list.dirs(skills_dir, recursive = FALSE, full.names = TRUE)

results <- lapply(dirs, function(d) {
  skill_file <- file.path(d, "SKILL.md")
  if (!file.exists(skill_file)) return(NULL)

  lines <- readLines(skill_file, warn = FALSE)
  dir_name <- basename(d)

  # Parse frontmatter
  fm_start <- which(lines == "---")[1]
  fm_end <- which(lines == "---")[2]
  fm_lines <- if (!is.na(fm_start) && !is.na(fm_end)) lines[(fm_start+1):(fm_end-1)] else character()

  # Extract fields
  name_line <- grep("^name:", fm_lines, value = TRUE)[1]
  name <- if (!is.na(name_line)) trimws(sub("^name:\\s*", "", name_line)) else ""

  # Description (handle multi-line >)
  desc_idx <- grep("^description:", fm_lines)
  desc <- ""
  if (length(desc_idx) > 0) {
    first_line <- sub("^description:\\s*>?\\s*", "", fm_lines[desc_idx[1]])
    if (nzchar(first_line)) {
      desc <- first_line
    }
    # Collect continuation lines
    for (i in seq(desc_idx[1] + 1, length(fm_lines))) {
      if (grepl("^\\s+", fm_lines[i])) {
        desc <- paste(desc, trimws(fm_lines[i]))
      } else break
    }
  }
  desc <- trimws(desc)

  # Body content
  body <- if (!is.na(fm_end)) lines[(fm_end+1):length(lines)] else lines
  body_text <- paste(body, collapse = "\n")

  # Checks
  has_gotchas <- any(grepl("## Gotchas|## Common Pitfalls|## Known Issues|## Pitfalls", body))
  has_scripts <- dir.exists(file.path(d, "scripts"))
  has_refs <- dir.exists(file.path(d, "references"))
  has_evals <- dir.exists(file.path(d, "evals"))
  has_examples <- dir.exists(file.path(d, "examples"))
  n_lines <- length(lines)

  # Description quality
  has_use_when <- grepl("Use (this |)when|Use (this |)skill when|TRIGGER when", desc, ignore.case = TRUE)
  desc_len <- nchar(desc)

  # Name validation
  name_ok <- grepl("^[a-z][a-z0-9.-]*[a-z0-9]$", name) && !grepl("--", name)
  name_matches_dir <- name == dir_name

  data.frame(
    skill = dir_name, name = name, name_ok = name_ok,
    name_matches_dir = name_matches_dir,
    desc_len = desc_len, has_use_when = has_use_when,
    has_gotchas = has_gotchas, has_scripts = has_scripts,
    has_refs = has_refs, has_evals = has_evals, has_examples = has_examples,
    n_lines = n_lines,
    stringsAsFactors = FALSE
  )
})

df <- do.call(rbind, Filter(Negate(is.null), results))

cat("=== SKILL AUDIT SUMMARY ===\n\n")
cat(sprintf("Total skills: %d\n", nrow(df)))
cat(sprintf("Name OK: %d / %d\n", sum(df$name_ok), nrow(df)))
cat(sprintf("Name matches dir: %d / %d\n", sum(df$name_matches_dir), nrow(df)))
cat(sprintf("Has 'Use when' trigger: %d / %d\n", sum(df$has_use_when), nrow(df)))
cat(sprintf("Description > 50 chars: %d / %d\n", sum(df$desc_len > 50), nrow(df)))
cat(sprintf("Has gotchas section: %d / %d\n", sum(df$has_gotchas), nrow(df)))
cat(sprintf("Has scripts/ dir: %d / %d\n", sum(df$has_scripts), nrow(df)))
cat(sprintf("Has references/ dir: %d / %d\n", sum(df$has_refs), nrow(df)))
cat(sprintf("Has evals/ dir: %d / %d\n", sum(df$has_evals), nrow(df)))
cat(sprintf("Has examples/ dir: %d / %d\n", sum(df$has_examples), nrow(df)))
cat(sprintf("Under 500 lines: %d / %d\n", sum(df$n_lines <= 500), nrow(df)))

cat("\n=== NEEDS WORK ===\n")
needs_work <- df[!df$has_use_when | df$desc_len < 50 | !df$name_ok, ]
if (nrow(needs_work) > 0) {
  for (i in seq_len(nrow(needs_work))) {
    issues <- character()
    if (!needs_work$has_use_when[i]) issues <- c(issues, "NO_TRIGGER")
    if (needs_work$desc_len[i] < 50) issues <- c(issues, "SHORT_DESC")
    if (!needs_work$name_ok[i]) issues <- c(issues, "BAD_NAME")
    cat(sprintf("%-35s %s\n", needs_work$skill[i], paste(issues, collapse = " ")))
  }
}
