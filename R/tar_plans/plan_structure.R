# R/tar_plans/plan_structure.R

# Source function analysis utilities (not auto-loaded since llm isn't always load_all'd)
source(here::here("R/function_analysis.R"), local = TRUE)

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

  # 4. Function Frequency Table
  tar_target(
    vig_function_frequency,
    {
      freq <- build_frequency_table("R")
      DT::datatable(
        freq, rownames = FALSE, filter = "top",
        options = list(pageLength = 20, scrollX = TRUE, order = list(list(2, "desc"))),
        caption = htmltools::tags$caption(
          style = "caption-side: top; text-align: left;",
          paste0(
            "Function call frequency across R/ source files (N = ", nrow(freq),
            " unique functions). ",
            "Top caller: ", freq$call[1], " (", freq$n_calls[1], " calls). ",
            "Source: static AST analysis of R/*.R files."
          )
        )
      )
    },
    packages = c("dplyr", "DT", "htmltools")
  ),

  # 5. Call Network (one level deep)
  tar_target(
    vig_call_network,
    {
      network <- build_call_network("R")
      if (nrow(network) == 0L) return(NULL)

      # Create visNetwork graph
      nodes_from <- unique(network$from)
      nodes_to <- unique(network$to)
      all_nodes <- unique(c(nodes_from, nodes_to))

      nodes <- tibble::tibble(
        id = all_nodes,
        label = sub(".*::", "", all_nodes),
        group = ifelse(all_nodes %in% nodes_from, "internal", "external"),
        title = all_nodes      )

      edges <- tibble::tibble(
        from = network$from,
        to = network$to      )

      visNetwork::visNetwork(nodes, edges,
        main = paste0("Call Network: ", length(nodes_from), " internal functions → ",
                       length(nodes_to), " external calls"),
        width = "100%", height = "600px"
      ) |>
        visNetwork::visGroups(groupname = "internal", color = list(background = "#2c3e50", border = "#1a252f")) |>
        visNetwork::visGroups(groupname = "external", color = list(background = "#95a5a6", border = "#7f8c8d")) |>
        visNetwork::visEdges(arrows = "to", color = list(color = "#CC0000")) |>
        visNetwork::visOptions(highlightNearest = TRUE, nodesIdSelection = TRUE) |>
        visNetwork::visLayout(randomSeed = 42)
    },
    packages = c("visNetwork")
  ),

  # 6. Git Stats (Comprehensive)
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
