# Function Analysis — Frequency Table + Call Network

Reusable static analysis for any R package project. Answers: "What functions does this project use, and how do our functions connect to external packages?"

## Setup (per project)

### 1. Source the analysis functions

The functions live in the llm project. Source them from any project:

```r
source("~/docs_gh/llm/R/function_analysis.R")
```

### 2. Add targets to plan_structure.R (or plan_telemetry.R)

```r
# Source function analysis utilities
source(here::here("~/docs_gh/llm/R/function_analysis.R"))

# Inside your plan list:

  # Function frequency table
  tar_target(
    vig_function_frequency,
    {
      freq <- build_frequency_table("R")
      DT::datatable(
        freq, rownames = FALSE, filter = "top",
        options = list(pageLength = 20, scrollX = TRUE, order = list(list(2, "desc"))),
        caption = htmltools::tags$caption(
          style = "caption-side: top; text-align: left;",
          paste0("Function call frequency (N = ", nrow(freq), " unique). ",
                 "Top: ", freq$call[1], " (", freq$n_calls[1], " calls). ",
                 "Source: AST analysis of R/*.R.")
        )
      )
    },
    packages = c("dplyr", "DT", "htmltools")
  ),

  # Call network (one level deep)
  tar_target(
    vig_call_network,
    {
      network <- build_call_network("R")
      if (nrow(network) == 0L) return(NULL)
      nodes_from <- unique(network$from)
      nodes_to <- unique(network$to)
      all_nodes <- unique(c(nodes_from, nodes_to))
      nodes <- data.frame(
        id = all_nodes,
        label = sub(".*::", "", all_nodes),
        group = ifelse(all_nodes %in% nodes_from, "internal", "external"),
        title = all_nodes, stringsAsFactors = FALSE
      )
      edges <- data.frame(from = network$from, to = network$to, stringsAsFactors = FALSE)
      visNetwork::visNetwork(nodes, edges,
        main = paste0(length(nodes_from), " internal → ", length(nodes_to), " external"),
        width = "100%", height = "600px"
      ) |>
        visNetwork::visGroups(groupname = "internal", color = list(background = "#2c3e50")) |>
        visNetwork::visGroups(groupname = "external", color = list(background = "#95a5a6")) |>
        visNetwork::visEdges(arrows = "to", color = list(color = "#CC0000")) |>
        visNetwork::visOptions(highlightNearest = TRUE, nodesIdSelection = TRUE) |>
        visNetwork::visLayout(randomSeed = 42)
    },
    packages = c("visNetwork")
  ),
```

### 3. Add to telemetry vignette

```qmd
## Function Usage

### Frequency Table

```{r fn-freq}
safe_tar_read("vig_function_frequency")
```

### Call Network

```{r fn-network}
safe_tar_read("vig_call_network")
```
```

## Available Functions

| Function | What It Does | Returns |
|----------|-------------|---------|
| `extract_file_calls(file)` | Walk AST of one R file, extract all function calls | data.frame(file, call, has_namespace) |
| `extract_function_defs(r_dir)` | Find all `fn <- function()` definitions | Named list of body expressions |
| `classify_call(name, our_fns)` | Determine package: `pkg::func`, `base`, `internal`, `unknown` | Character |
| `build_frequency_table(r_dir)` | Full frequency table across all R/ files | data.frame(call, package, n_calls, n_files) |
| `build_call_network(r_dir)` | One-level-deep call graph (our funcs → external) | data.frame(from, to, to_package) |

## Performance (llm project)

| Target | Time | Size | Functions | Edges |
|--------|------|------|-----------|-------|
| `vig_function_frequency` | 229ms | 7 KB | 307 | — |
| `vig_call_network` | 157ms | 6.5 KB | — | 880 |

Static AST analysis only — no code execution, negligible memory.

## Requirements

Packages: `dplyr`, `DT`, `htmltools`, `visNetwork` (all in Suggests).
No new dependencies — these are already used by most projects.
