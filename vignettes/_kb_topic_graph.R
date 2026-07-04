# _kb_topic_graph.R
# Builds the topic-graph adjacency RDS from knowledge/wiki/*.md.
# Scans [[link]] references and produces nodes + edges data frames.
# Run locally: Rscript vignettes/_kb_topic_graph.R
# Output: inst/extdata/vignettes/vig_kb_graph.rds

# --- Locate wiki directory ------------------------------------------------
kb_candidates <- c(
  file.path(here::here(), "knowledge", "wiki"),
  path.expand("~/docs_gh/llm/knowledge/wiki")
)
wiki_dir <- Find(dir.exists, kb_candidates)
if (is.null(wiki_dir)) {
  message("knowledge/wiki not found — saving NULL RDS")
  saveRDS(NULL, here::here("inst/extdata/vignettes/vig_kb_graph.rds"))
  quit(status = 0)
}

# --- Enumerate wiki pages -------------------------------------------------
wiki_files <- list.files(wiki_dir, pattern = "\\.md$",
                         full.names = TRUE, recursive = FALSE)
if (length(wiki_files) == 0) {
  message("No .md files in ", wiki_dir, " — saving NULL RDS")
  saveRDS(NULL, here::here("inst/extdata/vignettes/vig_kb_graph.rds"))
  quit(status = 0)
}

page_names <- tools::file_path_sans_ext(basename(wiki_files))

# Domain = first dash-separated token (e.g. "roborev" from "roborev-patterns")
domain_of <- function(nm) sub("-.*", "", nm)

# --- Extract [[link]] references -----------------------------------------
extract_wikilinks <- function(path) {
  text  <- paste(readLines(path, warn = FALSE), collapse = "\n")
  # perl=TRUE required: TRE (default) misparsed [^\]] inside char class
  m     <- gregexpr("\\[\\[.+?\\]\\]", text, perl = TRUE)
  raw   <- regmatches(text, m)[[1]]
  sub("^\\[\\[", "", sub("\\]\\]$", "", raw))
}

edges_list <- lapply(wiki_files, function(f) {
  src  <- tools::file_path_sans_ext(basename(f))
  tgts <- extract_wikilinks(f)
  if (length(tgts) == 0L) return(NULL)
  data.frame(from = src, to = tgts, stringsAsFactors = FALSE)
})

edges_df <- do.call(rbind, Filter(Negate(is.null), edges_list))
if (is.null(edges_df)) {
  edges_df <- data.frame(from = character(0L), to = character(0L),
                         stringsAsFactors = FALSE)
}

# --- Build node table -----------------------------------------------------
all_node_ids <- unique(c(page_names,
                          if (nrow(edges_df) > 0L) edges_df$to else character(0L)))

inbound_tbl <- if (nrow(edges_df) > 0L) table(edges_df$to) else integer(0L)

nodes_df <- data.frame(
  id      = all_node_ids,
  label   = all_node_ids,
  domain  = domain_of(all_node_ids),
  inbound = as.integer(inbound_tbl[all_node_ids]),
  broken  = !all_node_ids %in% page_names,
  stringsAsFactors = FALSE
)
nodes_df$inbound[is.na(nodes_df$inbound)] <- 0L
# orphan = existing page with zero inbound edges
nodes_df$orphan <- nodes_df$id %in% page_names & nodes_df$inbound == 0L

# --- Save -----------------------------------------------------------------
out_path <- here::here("inst/extdata/vignettes/vig_kb_graph.rds")
saveRDS(list(nodes = nodes_df, edges = edges_df), out_path)
message("Saved ", out_path,
        " — ", nrow(nodes_df), " nodes, ", nrow(edges_df), " edges")
