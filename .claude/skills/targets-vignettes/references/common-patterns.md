# Common Targets Patterns for Vignettes

## Pattern 1: Multiple Related Plots

```r
# _targets.R
tar_plan(
  # Generate a list of plots
  tar_target(
    plots_by_group,
    create_group_plots(clean_data)
  )
)

# R/plotting.R
create_group_plots <- function(data) {
  groups <- unique(data$group)

  plots <- lapply(groups, function(g) {
    subset_data <- data[data$group == g, ]
    ggplot(subset_data, aes(x = x, y = y)) +
      geom_point() +
      labs(title = paste("Group:", g))
  })

  names(plots) <- groups
  plots
}

# In vignette:
# tar_load(plots_by_group)
# plots_by_group$group1
# plots_by_group$group2
```

## Pattern 2: Conditional Targets

```r
# _targets.R
tar_plan(
  tar_target(use_cache, file.exists("cache/data.rds")),

  tar_target(
    data,
    if (use_cache) {
      readRDS("cache/data.rds")
    } else {
      fetch_and_process_data()
    }
  )
)
```

## Pattern 3: File Targets

```r
# _targets.R
tar_plan(
  # Save a file and track it
  tar_target(
    report_pdf,
    {
      rmarkdown::render("report.Rmd", output_file = "report.pdf")
      "report.pdf"
    },
    format = "file"
  )
)
```

## Pattern 4: Dynamic Branching

```r
# _targets.R
tar_plan(
  tar_target(input_files, list.files("data-raw", full.names = TRUE)),

  tar_target(
    processed_data,
    process_file(input_files),
    pattern = map(input_files)
  ),

  tar_target(combined_data, bind_rows(processed_data))
)
```

## Telemetry Vignette Pattern

Create a vignette that shows project statistics:

```r
# _targets.R
tar_plan(
  # ... your main pipeline ...

  # Telemetry targets
  tar_target(pipeline_meta, tar_meta()),
  tar_target(git_history, get_git_stats()),
  tar_target(package_structure, get_file_tree()),
  tar_target(test_coverage, get_coverage_stats()),
  tar_target(session_info, sessionInfo())
)

# R/telemetry.R
get_git_stats <- function() {
  library(gert)

  log <- gert::git_log(max = 100)

  list(
    total_commits = nrow(log),
    contributors = unique(log$author),
    recent_activity = log[1:10, ]
  )
}

get_file_tree <- function() {
  library(fs)

  tree <- fs::dir_tree(recurse = TRUE)
  capture.output(tree)
}

get_coverage_stats <- function() {
  library(covr)

  cov <- package_coverage()

  list(
    percent = percent_coverage(cov),
    by_file = coverage_by_file(cov)
  )
}
```
