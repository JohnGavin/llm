# R/tar_plans/plan_structure.R

plan_structure <- list(
  # 1. Track all files (trigger for structure changes)
  # using list.files directly as a trigger is inefficient for large repos if strictly "file" format
  # instead we track the list of paths as character vector
  tar_target(
    all_file_paths,
    list.files(recursive = TRUE, full.names = TRUE),
    cue = tar_cue(mode = "always") # Always check for new files
  ),

  # 2. File Tree (Text Output)
  tar_target(
    project_file_tree,
    {
      # Force dependency
      force(all_file_paths)
      capture.output(fs::dir_tree(recurse = 2)) |>
        paste(collapse = "\n")
    }
  ),

  # 3. File Counts (Tibble)
  tar_target(
    file_type_counts,
    {
      # Force dependency
      force(all_file_paths)
      
      tibble::tibble(path = all_file_paths) |>
        dplyr::filter(!grepl("(\\.git|_targets|renv)", path)) |>
        dplyr::mutate(ext = tools::file_ext(path)) |>
        dplyr::count(ext, sort = TRUE)
    }
  ),

  # 4. Git Stats (Comprehensive)
  tar_target(
    git_stats_comprehensive,
    {
      # Run in tryCatch as it depends on API/network
      tryCatch({
        owner <- "JohnGavin"
        repo <- "llm"
        
        # Commits
        commits <- gert::git_log(max = 1000)
        
        # Issues (requires gh)
        issues <- gh::gh("/repos/{owner}/{repo}/issues", owner = owner, repo = repo, state = "all", per_page = 100)
        
        # Actions (requires gh)
        runs <- gh::gh("/repos/{owner}/{repo}/actions/runs", owner = owner, repo = repo, per_page = 100)
        
        list(
          total_commits = nrow(commits),
          last_commit = max(commits$time),
          authors = length(unique(commits$author)),
          open_issues = length(Filter(function(x) x$state == "open" && is.null(x$pull_request), issues)),
          closed_issues = length(Filter(function(x) x$state == "closed" && is.null(x$pull_request), issues)),
          total_runs = length(runs$workflow_runs),
          recent_runs = runs$workflow_runs[1:min(10, length(runs$workflow_runs))]
        )
      }, error = function(e) {
        warning("Git stats failed: ", e$message)
        NULL
      })
    },
    cue = tar_cue(mode = "always") # Always refresh stats
  )
)
