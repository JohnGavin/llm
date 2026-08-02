# Reconciling the two disjoint ccusage daily cache windows (llm#870)
#
# The in-package cache (inst/extdata/ccusage_daily_all.json) and the
# llmtelemetry cache of the same name cover non-overlapping date ranges
# (2026-01-10..2026-05-09 vs 2026-06-29..2026-08-01) and record project names
# using two different schemes:
#
#   old (llm, frozen):    dash-mangled absolute paths, e.g.
#                          "-Users-johngavin-docs-gh-proj-stats-simulations-randomwalk"
#   new (llmtelemetry):   short canonical names ("llm", "historical") plus
#                          ephemeral per-agent worktree paths
#                          ("llm//claude/worktrees/agent/<hash>")
#
# canonicalize_ccusage_project() maps both schemes onto one key so a
# per-project series can be continued across the boundary, and
# merge_ccusage_daily() unions the two windows on (canonical project, date).
#
# This reimplements (does not copy) the pattern logic in
# llmtelemetry/R/canonicalize.R::canonicalize_project() — see llm#652 for the
# fuller session-level canonicalisation audit this is deliberately scoped
# down from. Two differences from that reference implementation, both
# intentional for this use case:
#
#   1. Noise/ephemeral entries here bucket into the sentinel "<ephemeral>"
#      rather than becoming NA, so their spend still shows up in date-level
#      totals instead of being silently dropped.
#   2. The alias table is limited to the handful of overrides verified
#      against the actual cache files (see the investigation on llm#870);
#      it is not a port of llmtelemetry's full alias list.

#' Sentinel returned for noise / ephemeral ccusage project entries
#'
#' Runtime-ephemeral entries (agent worktree hashes, roborev worktrees,
#' branch-fragment tokens) canonicalise to this value rather than `NA`, so
#' their cost is still visible in date-level totals without polluting
#' per-real-project series. See [canonicalize_ccusage_project()].
#'
#' @keywords internal
CCUSAGE_EPHEMERAL <- "<ephemeral>"

# Branch/worktree suffixes appended with a dash: stripped before further
# parsing so "llm-feat-cc-20260524-102501" doesn't get sliced into "feat".
.ccusage_branch_suffix_re <- paste0(
  "-(feat|fix|chore|docs|refactor|test|ci|perf|style|build|revert|wt|",
  "sonnet|haiku|opus|worktree)(-.*)?$"
)

# Single-pass container-prefix strip: compound (two-segment) entries must
# come before their single-segment components so "finance-data-x" strips as
# one unit rather than leaving "data-x" behind.
.ccusage_container_prefixes <- c(
  "stats-simulations-", "stats-sport-", "finance-data-",
  "data-", "stats-", "simulations-", "sport-", "crypto-",
  "subagents-", "knowledge-", "github-", "antigravity-", "hello-",
  "pers-", "finance-"
)

# Bare tokens (as the sole remaining first segment) that carry no project
# information and bucket to the ephemeral sentinel.
.ccusage_meta_only <- c(
  "unknown", "worktree", "worktrees",
  "feat", "fix", "chore", "ci", "perf", "style", "build", "revert",
  "wt", "docs", "project", "agent", "roborev",
  "sonnet", "haiku", "opus", "cc", "eval", "io", "t",
  "notmineraft", "demos", "wiki", "subagents", "knowledge",
  "github", "antigravity", "hello"
)

# Verified real-project aliases (checked against the actual llm/llmtelemetry
# cache files during the llm#870 investigation). Deliberately small — this
# is NOT a port of llmtelemetry's full alias table; extending it further is
# llm#652 territory.
.ccusage_overrides <- c(
  "weather-irish-buoy-network" = "irish_buoy_network",
  "irish-buoy-network"         = "irish_buoy_network",
  "buoy-network"                = "irish_buoy_network"
)

#' Canonicalise a raw ccusage project name
#'
#' @param name Single character value (raw project/session-path string).
#' @return Canonical single-token project name, or [CCUSAGE_EPHEMERAL] for
#'   noise / runtime-ephemeral entries.
#' @keywords internal
.canonicalize_ccusage_project_one <- function(name) {
  if (is.na(name) || !nzchar(name)) return(NA_character_)

  # --- ephemeral checks on the ORIGINAL string, before any normalisation ---

  # New-scheme per-agent worktree paths: "llm//claude/worktrees/agent/<hash>"
  if (grepl("claude/worktrees/agent/", name, fixed = TRUE)) {
    return(CCUSAGE_EPHEMERAL)
  }
  # Old-scheme roborev worktree checkouts: "-private-tmp-roborev-worktree-<n>"
  if (grepl("roborev-worktree-[0-9]+", name) ||
      grepl("(^|-)worktree-[0-9]+", name)) {
    return(CCUSAGE_EPHEMERAL)
  }
  # Old-scheme random-hash tmp clones: "-private-tmp-tmp-<hash>-repo"
  if (grepl("tmp-[A-Za-z0-9]{6,}-repo$", name)) {
    return(CCUSAGE_EPHEMERAL)
  }
  # Bare agent-worktree hash tokens, with or without an "agent-" prefix.
  if (grepl("^agent-[0-9a-f]{6,}$", name, ignore.case = TRUE) ||
      grepl("^[0-9a-f]{12,}$", name, ignore.case = TRUE)) {
    return(CCUSAGE_EPHEMERAL)
  }
  # Session-id branch tokens: "cc-20260524-102501" (with or without leading dash)
  if (grepl("^-?cc-?[0-9]{8}-[0-9]{6}", name)) {
    return(CCUSAGE_EPHEMERAL)
  }

  # --- normalise separators and known absolute-path prefixes ---

  x <- gsub("/", "-", name, fixed = TRUE)
  x <- sub("^-Users-johngavin-docs--pers-NHS-health-data-antigravity-", "", x)
  x <- sub("^-Users-[^-]+-docs-gh-", "", x)
  x <- sub("^-private-tmp-", "", x)

  # "proj" segment marker: paths recorded via the nested proj/ tree
  # (docs_gh/proj/<domain>/...) get an unrelated top-level dir glued on the
  # front by the hook; drop everything up to and including "proj" so the
  # real leaf segments are what remain.
  segs <- strsplit(x, "-", fixed = TRUE)[[1]]
  proj_idx <- which(segs == "proj")
  if (length(proj_idx) > 0L) segs <- segs[(proj_idx[1L] + 1L):length(segs)]
  x <- paste(segs, collapse = "-")
  if (!nzchar(x)) return(CCUSAGE_EPHEMERAL)

  # Strip a trailing branch/worktree-type suffix.
  x <- sub(.ccusage_branch_suffix_re, "", x, perl = TRUE, ignore.case = TRUE)
  if (!nzchar(x)) return(CCUSAGE_EPHEMERAL)

  # Single-pass container-prefix strip.
  for (pfx in .ccusage_container_prefixes) {
    if (startsWith(x, pfx)) {
      x <- sub(paste0("^", pfx), "", x)
      break
    }
  }
  if (!nzchar(x)) return(CCUSAGE_EPHEMERAL)

  # Verified real-project overrides, checked on the (possibly multi-segment)
  # remainder before we collapse down to a single first segment.
  for (pat in names(.ccusage_overrides)) {
    if (startsWith(x, pat)) return(.ccusage_overrides[[pat]])
  }

  first <- strsplit(x, "-", fixed = TRUE)[[1]][1]
  if (!nzchar(first)) return(CCUSAGE_EPHEMERAL)
  if (grepl("^[0-9]+$", first)) return(CCUSAGE_EPHEMERAL)
  if (grepl("^[0-9a-f]{12,}$", first, ignore.case = TRUE)) return(CCUSAGE_EPHEMERAL)
  if (first %in% .ccusage_meta_only) return(CCUSAGE_EPHEMERAL)

  first
}

#' Canonicalise raw ccusage project names to a shared key
#'
#' The llm and llmtelemetry ccusage daily caches record project names using
#' two different schemes (see the file-level comment in `ccusage_merge.R`).
#' This maps both onto one canonical key so [merge_ccusage_daily()] can union
#' the two windows on `(project, date)`.
#'
#' Ephemeral runtime artefacts (agent-worktree hashes, roborev worktrees,
#' session-id branch names) canonicalise to the sentinel `"<ephemeral>"`
#' rather than `NA`, so their spend remains visible in date-level totals
#' instead of being dropped.
#'
#' @param x Character vector of raw project names, as recorded in either
#'   ccusage cache's `projects` list names.
#' @return Character vector the same length as `x`. `NA` in is `NA` out;
#'   noise/ephemeral entries become `"<ephemeral>"`; everything else becomes
#'   its canonical single-token project name.
#' @examples
#' canonicalize_ccusage_project(c(
#'   "-Users-johngavin-docs-gh-llm",
#'   "llm//claude/worktrees/agent/a8a55593cef9747a7",
#'   "-private-tmp-roborev-worktree-1248728332",
#'   "historical"
#' ))
#' # [1] "llm"          "<ephemeral>"  "<ephemeral>"  "historical"
#' @export
canonicalize_ccusage_project <- function(x) {
  checkmate::assert_character(x, null.ok = TRUE)
  if (is.null(x) || length(x) == 0L) return(character(0))
  vapply(x, .canonicalize_ccusage_project_one, character(1), USE.NAMES = FALSE)
}

#' Locate every available ccusage daily cache file
#'
#' Unlike [ccusage_cache_file()] (package-copy-first, returns a single
#' path), this returns every window that actually exists so
#' [merge_ccusage_daily()] can union them (llm#870). Order in the returned
#' named vector is not meaningful; names identify the source.
#'
#' @return Named character vector, names in `c("llm", "llmtelemetry")`,
#'   values are file paths. Length 0, 1, or 2 depending on what is present.
#' @keywords internal
ccusage_daily_cache_paths <- function() {
  paths <- character(0)

  pkg_dir <- ccusage_pkg_cache_dir()
  if (!is.null(pkg_dir)) {
    f <- file.path(pkg_dir, "ccusage_daily_all.json")
    if (file.exists(f)) paths <- c(paths, llm = f)
  }

  telemetry_dir <- file.path(
    Sys.getenv("LLM_PROJECTS_ROOT", file.path(Sys.getenv("HOME"), "docs_gh")),
    "llmtelemetry", "inst", "extdata"
  )
  f2 <- file.path(telemetry_dir, "ccusage_daily_all.json")
  if (file.exists(f2)) paths <- c(paths, llmtelemetry = f2)

  paths
}

# Numeric columns present in parse_ccusage_json()'s output that are
# additive (token counts, cost).
.ccusage_daily_numeric_cols <- c(
  "inputTokens", "outputTokens", "cacheCreationTokens",
  "cacheReadTokens", "totalTokens", "totalCost"
)

#' Collapse multiple raw-project rows onto one row per canonical project/date
#'
#' Many raw project names canonicalise to the same key (e.g. every
#' `-private-tmp-roborev-worktree-<n>` entry becomes `"<ephemeral>"`), so a
#' single source window can have several rows sharing one `(project, date)`
#' pair after canonicalisation. Those rows represent genuinely distinct
#' spend that must be **summed**, not deduplicated — picking just one would
#' silently discard real cost/token data. This is the "within one source"
#' half of [merge_ccusage_daily()]'s two-phase aggregation; the "across
#' sources" half (`llmtelemetry` wins on true overlap) runs after this, once
#' each source has at most one row per `(project, date)`.
#'
#' @param df A tibble already tagged with `project` (canonicalised),
#'   `project_raw`, and `source_window` columns, or `NULL`.
#' @return `df` collapsed to one row per `(project, date, source_window)`,
#'   or `NULL`/unchanged if `df` is `NULL`/empty.
#' @keywords internal
.aggregate_ccusage_window <- function(df) {
  if (is.null(df) || nrow(df) == 0L) return(df)

  present_numeric <- intersect(.ccusage_daily_numeric_cols, names(df))

  summarised <- df |>
    dplyr::group_by(project, date, source_window) |>
    dplyr::summarise(
      dplyr::across(dplyr::all_of(present_numeric), ~ sum(.x, na.rm = TRUE)),
      project_raw = paste(sort(unique(project_raw)), collapse = "; "),
      .groups = "drop"
    )

  # List columns (modelsUsed, modelBreakdowns) need a different reducer than
  # sum(), so they are aggregated separately and joined back on.
  if ("modelsUsed" %in% names(df)) {
    models_agg <- df |>
      dplyr::group_by(project, date, source_window) |>
      dplyr::summarise(
        modelsUsed = list(unique(unlist(modelsUsed))),
        .groups = "drop"
      )
    summarised <- dplyr::left_join(
      summarised, models_agg,
      by = c("project", "date", "source_window")
    )
  }
  if ("modelBreakdowns" %in% names(df)) {
    breakdowns_agg <- df |>
      dplyr::group_by(project, date, source_window) |>
      dplyr::summarise(
        modelBreakdowns = list(dplyr::bind_rows(modelBreakdowns)),
        .groups = "drop"
      )
    summarised <- dplyr::left_join(
      summarised, breakdowns_agg,
      by = c("project", "date", "source_window")
    )
  }

  summarised
}

#' Union the two ccusage daily cache windows into one series
#'
#' Both `llm_data` and `telemetry_data` are expected in the shape returned
#' by [parse_ccusage_json()] (one row per project x date, `project` holding
#' the raw project name). This canonicalises `project` on both sides via
#' [canonicalize_ccusage_project()] and unions them on `(project, date)` in
#' two phases:
#'
#' 1. **Within each source**, rows whose raw project names canonicalise to
#'    the same `(project, date)` are summed via
#'    [.aggregate_ccusage_window()] — they are genuinely distinct spend
#'    (e.g. several different `-private-tmp-roborev-worktree-<n>` entries on
#'    the same day, all bucketed to `"<ephemeral>"`), not duplicate
#'    observations, so picking just one would silently drop real cost data.
#' 2. **Across sources**, a `(project, date)` pair present in both windows
#'    is deduplicated (not summed) — the `llmtelemetry` row wins, because it
#'    is the actively-refreshed source (#32) and a same-project/same-date
#'    collision here would represent the same underlying observation
#'    recorded twice, not two different things to add together. The two
#'    windows currently do not overlap in date at all, so this rule is
#'    exercised only by tests today, not by real data — but a future cache
#'    refresh could create overlap, so it is implemented now rather than
#'    deferred.
#'
#' The 2026-05-10..2026-06-28 gap between the two windows is **not**
#' interpolated or filled — it is simply the set of dates with no row on
#' either side. [find_activity_gaps()] run against the merged result
#' surfaces it (and any other gap) as an explicit range; the result is also
#' attached as the `"ccusage_gaps"` attribute so callers do not have to
#' recompute it.
#'
#' @param llm_data Tibble from parsing `llm`'s own daily cache, or `NULL`.
#' @param telemetry_data Tibble from parsing `llmtelemetry`'s daily cache,
#'   or `NULL`.
#' @return A tibble with all of `llm_data`/`telemetry_data`'s original
#'   columns, plus:
#'   - `project_raw`: the raw project name(s) that rolled up into this row,
#'     joined with `"; "` when more than one contributed
#'   - `project`: canonicalised via [canonicalize_ccusage_project()]
#'     (overwrites the original `project` column)
#'   - `source_window`: `"llm"` or `"llmtelemetry"` — which cache the row
#'     was read from (the winning side, on cross-source overlap)
#'
#'   `NULL` if both inputs are `NULL`/empty. The `"ccusage_gaps"` attribute
#'   holds the [find_activity_gaps()] result over the merged dates.
#' @export
merge_ccusage_daily <- function(llm_data = NULL, telemetry_data = NULL) {
  checkmate::assert_data_frame(llm_data, null.ok = TRUE)
  checkmate::assert_data_frame(telemetry_data, null.ok = TRUE)

  tag_source <- function(df, tag) {
    if (is.null(df) || nrow(df) == 0L) return(NULL)
    df |>
      dplyr::mutate(
        project_raw = project,
        project = canonicalize_ccusage_project(project),
        source_window = tag,
        date = as.character(date)
      ) |>
      .aggregate_ccusage_window()
  }

  combined <- dplyr::bind_rows(
    tag_source(llm_data, "llm"),
    tag_source(telemetry_data, "llmtelemetry")
  )

  if (is.null(combined) || nrow(combined) == 0L) return(NULL)

  # Phase 2: across sources, same (project, date) present in both windows --
  # the llmtelemetry copy is the actively-refreshed source (#32), so it
  # wins. Each source has already been collapsed to <=1 row per
  # (project, date) by tag_source()/.aggregate_ccusage_window(), so this is
  # a plain dedup (pick the higher-ranked row), not a further sum.
  combined <- combined |>
    dplyr::mutate(
      source_rank = ifelse(source_window == "llmtelemetry", 2L, 1L)
    ) |>
    dplyr::arrange(project, date, source_rank) |>
    dplyr::group_by(project, date) |>
    dplyr::slice_tail(n = 1) |>
    dplyr::ungroup() |>
    dplyr::select(-"source_rank") |>
    dplyr::arrange(date, project)

  attr(combined, "ccusage_gaps") <- find_activity_gaps(combined)
  combined
}
