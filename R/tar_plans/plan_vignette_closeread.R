plan_vignette_closeread <- function() {
  list(
    # 1. Infrastructure counts from ~/.claude/
    tar_target(
      vig_cr_infra_counts,
      tryCatch({
        claude_dir <- path.expand("~/.claude")

        # Count skills from MANIFEST.md (authoritative source)
        manifest_path <- file.path(claude_dir, "skills", "MANIFEST.md")
        n_skills <- if (file.exists(manifest_path)) {
          lines <- readLines(manifest_path, warn = FALSE)
          skill_lines <- grep("^\\|", lines)
          # Exclude header and separator rows
          skill_lines <- skill_lines[!grepl("^\\| Skill|^\\|---", lines[skill_lines])]
          length(skill_lines)
        } else {
          # Fallback: count directories only (exclude .md files)
          dirs <- list.dirs(file.path(claude_dir, "skills"),
                           recursive = FALSE, full.names = FALSE)
          length(dirs)
        }

        list(
          n_rules    = length(list.files(file.path(claude_dir, "rules"),
                                         pattern = "\\.md$", recursive = TRUE)),
          n_skills   = n_skills,
          n_agents   = length(list.files(file.path(claude_dir, "agents"),
                                         pattern = "\\.md$", recursive = TRUE)),
          n_hooks    = length(list.files(file.path(claude_dir, "hooks"),
                                         pattern = "\\.sh$")),
          n_commands = length(list.files(file.path(claude_dir, "commands"),
                                         pattern = "\\.md$", recursive = TRUE)),
          n_memory   = length(list.files(
            file.path(claude_dir, "projects", "-Users-johngavin-docs-gh-llm", "memory"),
            pattern = "\\.md$"
          ))
        )
      }, error = function(e) {
        cli::cli_warn("vig_cr_infra_counts fallback: {conditionMessage(e)}")
        list(
          n_rules = 45L, n_skills = 72L, n_agents = 12L,
          n_hooks = 8L, n_commands = 14L, n_memory = 14L
        )
      }),
      packages = c("cli"),
      cue = tar_cue(mode = "always")
    ),

    # 1b. Summary-table caption — dynamic layer counts, never hand-typed
    tar_target(
      vig_cr_summary_caption,
      {
        n <- vig_cr_infra_counts
        paste0(
          "The six layers of the config stack: ", n$n_rules, " rules, ",
          n$n_skills, " skills, ", n$n_agents, " agents, ", n$n_memory,
          " memory files, ", n$n_commands, " commands, ", n$n_hooks, " hooks"
        )
      }
    ),

    # 2. Software layer diagram
    tar_target(
      vig_cr_layer_diagram,
      paste0(
        'graph TD\n',
        '  OS["OS: macOS / Linux"]\n',
        '  Nix["Nix + rix<br/>Reproducible shells"]\n',
        '  Pkgs["R / Python packages<br/>Project-specific"]\n',
        '  Orch["targets + crew + mirai<br/>Pipeline orchestration"]\n',
        '  LLM["LLM harness<br/>Rules + Skills + Agents"]\n',
        '  Out["Outputs<br/>Vignettes, APIs, Reports"]\n',
        '  OS --> Nix --> Pkgs --> Orch --> LLM --> Out\n',
        '  style OS fill:#999999,stroke:#CC0000,color:#000000\n',
        '  style Nix fill:#999999,stroke:#CC0000,color:#000000\n',
        '  style Pkgs fill:#999999,stroke:#CC0000,color:#000000\n',
        '  style Orch fill:#999999,stroke:#CC0000,color:#000000\n',
        '  style LLM fill:#999999,stroke:#CC0000,color:#000000\n',
        '  style Out fill:#999999,stroke:#CC0000,color:#000000\n',
        '  linkStyle default stroke:#CC0000,stroke-width:2px\n'
      )
    ),

    # 3. Harness hub diagram — uses counts including memory
    tar_target(
      vig_cr_harness_diagram,
      {
        n <- vig_cr_infra_counts
        paste0(
          'graph LR\n',
          '  A["AGENTS.md<br/>Entry point"]\n',
          sprintf('  R["Rules<br/>%d files"]', n$n_rules), '\n',
          sprintf('  S["Skills<br/>%d modules"]', n$n_skills), '\n',
          sprintf('  G["Agents<br/>%d definitions"]', n$n_agents), '\n',
          sprintf('  H["Hooks<br/>%d scripts"]', n$n_hooks), '\n',
          sprintf('  C["Commands<br/>%d slash cmds"]', n$n_commands), '\n',
          sprintf('  M["Memory<br/>%d files"]', n$n_memory), '\n',
          '  A --> R\n  A --> S\n  A --> G\n  A --> H\n  A --> C\n  A --> M\n',
          '  style A fill:#999999,stroke:#CC0000,color:#000000\n',
          '  style R fill:#999999,stroke:#CC0000,color:#000000\n',
          '  style S fill:#999999,stroke:#CC0000,color:#000000\n',
          '  style G fill:#999999,stroke:#CC0000,color:#000000\n',
          '  style H fill:#999999,stroke:#CC0000,color:#000000\n',
          '  style C fill:#999999,stroke:#CC0000,color:#000000\n',
          '  style M fill:#999999,stroke:#CC0000,color:#000000\n',
          '  linkStyle default stroke:#CC0000,stroke-width:2px\n'
        )
      }
    ),

    # 4. irishbuoys pipeline DAG (Section 3 case study)
    tar_target(
      vig_cr_pipeline_dag,
      paste0(
        'graph TD\n',
        '  acq["Data Acquisition<br/>ERDDAP API"]:::data\n',
        '  val["Data Validation<br/>8 QA targets"]:::qa\n',
        '  qc["Quality Control<br/>Physical bounds"]:::qa\n',
        '  wave["Wave Analysis<br/>61 targets"]:::analysis\n',
        '  joint["Joint Analysis<br/>Cross-station"]:::analysis\n',
        '  sev["Spatial Extremes<br/>EVA models"]:::analysis\n',
        '  pred["Predictions<br/>Forecasts"]:::analysis\n',
        '  alert["Storm Alerts<br/>Threshold triggers"]:::output\n',
        '  email["Email Report<br/>blastula"]:::output\n',
        '  dash["Dashboard<br/>bslib + plotly"]:::output\n',
        '  api["Static API<br/>JSON endpoints"]:::output\n',
        '  site["pkgdown Site<br/>Vignettes"]:::output\n',
        '  qa["QA Gates<br/>Bronze/Silver/Gold"]:::qa\n',
        '  acq --> val --> qc --> wave\n',
        '  wave --> joint --> sev\n',
        '  wave --> pred --> alert --> email\n',
        '  wave --> dash\n  wave --> api\n',
        '  joint --> site\n  qa --> site\n',
        '  classDef data fill:#999999,stroke:#CC0000,color:#000000\n',
        '  classDef qa fill:#666666,stroke:#CC0000,color:#FFFFFF\n',
        '  classDef analysis fill:#999999,stroke:#CC0000,color:#000000\n',
        '  classDef output fill:#BBBBBB,stroke:#CC0000,color:#000000\n',
        '  linkStyle default stroke:#CC0000,stroke-width:2px\n'
      )
    ),

    # 5. FOCUS flowchart
    tar_target(
      vig_cr_focus_diagram,
      paste0(
        'flowchart LR\n',
        '  F["Find<br/>Glob, Grep, Explore agent"]:::step\n',
        '  O["Organize<br/>AGENTS.md, Plan agent"]:::step\n',
        '  C["Condense<br/>Memory, ctx.yaml cache"]:::step\n',
        '  U["Understand<br/>r-debugger, critic"]:::step\n',
        '  Sy["Synthesize<br/>fixer, targets-runner"]:::step\n',
        '  F --> O --> C --> U --> Sy\n',
        '  classDef step fill:#999999,stroke:#CC0000,color:#000000\n',
        '  linkStyle default stroke:#CC0000,stroke-width:2px\n'
      )
    ),

    # 6. Pipeline walkthrough data (irishbuoys plan layers)
    tar_target(
      vig_cr_pipeline_walkthrough,
      tibble::tibble(
        plan = c(
          "plan_data_acquisition", "plan_data_validation", "plan_quality_control",
          "plan_wave_analysis", "plan_joint_analysis", "plan_spatial_extreme_values",
          "plan_predictions", "plan_storm_alert", "plan_email_report",
          "plan_dashboard", "plan_dashboard_vignette", "plan_wave_vignette",
          "plan_api", "plan_doc_examples", "plan_evidence",
          "plan_telemetry", "plan_qa_gates", "plan_pkgdown", "plan_pkgctx"
        ),
        layer = c(
          "Data", "QA", "QA",
          "Analysis", "Analysis", "Analysis",
          "Analysis", "Output", "Output",
          "Output", "Output", "Output",
          "Output", "Documentation", "Documentation",
          "Telemetry", "QA", "Output", "Tooling"
        ),
        software = c(
          "DuckDB, ERDDAP", "dplyr, pointblank", "dplyr",
          "targets, dplyr", "targets, dplyr", "targets, extRemes",
          "targets, dplyr", "targets, cli", "blastula, glue",
          "bslib, plotly", "bslib, plotly, DT", "Quarto, plotly",
          "plumber, jsonlite", "Quarto, knitr", "Quarto, knitr",
          "logger, targets", "targets, cli", "pkgdown, Quarto", "pkgctx"
        ),
        description = c(
          "Fetch hourly buoy data from Marine Institute ERDDAP",
          "Temporal coverage, gaps, duplicates, freshness, sampling frequency",
          "Physical range checks on wave height, period, direction",
          "Wave statistics, rolling aggregations, extreme value analysis",
          "Cross-station correlations, spatial patterns",
          "Spatial extreme value models (max-stable processes)",
          "Short-term wave height and period forecasts",
          "Beaufort-scale threshold alerts for each station",
          "Automated HTML email with storm warnings and summaries",
          "Interactive dashboard with range sliders and filters",
          "Dashboard vignette with pre-computed plotly charts",
          "Wave analysis vignette with scrollytelling",
          "JSON API endpoints for wave data and forecasts",
          "Code examples with parse-validated targets",
          "Claims-to-evidence mapping for vignette QA",
          "Pipeline metrics, timing, token usage logging",
          "Bronze/Silver/Gold quality scoring before merge",
          "pkgdown site build and deployment",
          "Package context YAML cache for LLM consumption"
        )
      ),
      packages = c("tibble")
    ),

    # 7. Pipeline DAG mermaid with layer colours
    tar_target(
      vig_cr_pipeline_dag_mermaid,
      paste0(
        'graph LR\n',
        '  acq["ERDDAP fetch<br/>DuckDB store"]:::data\n',
        '  val["8 validation<br/>targets"]:::qa\n',
        '  wave["61 wave<br/>analysis targets"]:::analysis\n',
        '  alert["Storm alerts<br/>+ email"]:::output\n',
        '  site["Dashboard<br/>+ pkgdown"]:::output\n',
        '  qa["QA gates<br/>Bronze/Silver/Gold"]:::qa\n',
        '  acq --> val --> wave\n',
        '  wave --> alert\n  wave --> site\n',
        '  qa --> site\n',
        '  classDef data fill:#999999,stroke:#CC0000,color:#000000\n',
        '  classDef qa fill:#666666,stroke:#CC0000,color:#FFFFFF\n',
        '  classDef analysis fill:#999999,stroke:#CC0000,color:#000000\n',
        '  classDef output fill:#BBBBBB,stroke:#CC0000,color:#000000\n',
        '  linkStyle default stroke:#CC0000,stroke-width:2px\n'
      )
    ),

    # 8. Build info footer
    tar_target(
      vig_cr_build_info,
      {
        version <- tryCatch(
          as.character(utils::packageVersion("llm")),
          error = function(e) "dev"
        )
        sha <- tryCatch(
          substr(gert::git_commit_info()$id, 1, 7),
          error = function(e) "unknown"
        )
        r_ver <- paste0(R.version$major, ".", R.version$minor)
        sprintf(
          'llm %s | Git [%s](https://github.com/JohnGavin/llm/commit/%s) | R %s | Built %s',
          version, sha, sha, r_ver, format(Sys.time(), "%Y-%m-%d %H:%M")
        )
      },
      packages = c("gert"),
      cue = tar_cue(mode = "always")
    ),

    # 9. Rule categories — scan ~/.claude/rules/*.md, categorize by keyword
    tar_target(
      vig_cr_rule_categories,
      tryCatch({
        rule_files <- list.files("~/.claude/rules", pattern = "\\.md$", full.names = TRUE)
        category_keywords <- list(
          Core       = c("orchestrator", "planning", "delegation", "debugging", "verification", "protocol", "confidence", "provenance"),
          Nix        = c("nix", "shell"),
          Git        = c("git", "deletion", "safe-deletion"),
          Data       = c("data", "duckdb", "duck", "missing", "station"),
          Stats      = c("statistic", "robust", "half-life", "composite", "suppress"),
          Backtest   = c("backtest", "look-ahead", "execution-delay", "position", "risk", "robustness", "snapshot", "strategy"),
          Viz        = c("visualization", "diagram", "reproducible-visualization"),
          Quarto     = c("quarto", "vignette"),
          Shiny      = c("shiny", "shinylive", "module"),
          Pipeline   = c("pipeline", "targets", "qa-targets", "ctx-yaml"),
          Knowledge  = c("wiki", "glossary"),
          Medical    = c("medical"),
          Other      = character(0)
        )
        categorize_rule <- function(fname) {
          base <- tools::file_path_sans_ext(basename(fname))
          for (cat in names(category_keywords)) {
            kws <- category_keywords[[cat]]
            if (length(kws) > 0 && any(grepl(paste(kws, collapse = "|"), base, ignore.case = TRUE)))
              return(cat)
          }
          "Other"
        }
        cats <- vapply(rule_files, categorize_rule, character(1))
        tbl <- tibble::tibble(
          category    = names(category_keywords),
          count       = vapply(names(category_keywords), function(c) sum(cats == c), integer(1)),
          example_rule = vapply(names(category_keywords), function(c) {
            idx <- which(cats == c)
            if (length(idx) == 0) NA_character_
            else tools::file_path_sans_ext(basename(rule_files[idx[[1]]]))
          }, character(1))
        )
        tbl[tbl$count > 0, ]
      }, error = function(e) {
        cli::cli_warn("vig_cr_rule_categories fallback: {conditionMessage(e)}")
        tibble::tibble(
          category     = c("Core", "Nix", "Git", "Data", "Stats", "Backtest", "Viz", "Quarto", "Shiny", "Pipeline", "Knowledge", "Medical", "Other"),
          count        = c(5L, 2L, 2L, 7L, 5L, 8L, 3L, 6L, 3L, 3L, 3L, 2L, 1L),
          example_rule = c("orchestrator-protocol", "nix-agent-shell-protocol", "git-no-compound-cd",
                           "data-validation-timeseries", "robust-statistics", "backtest-robustness",
                           "visualization-standards", "quarto-vignette-format", "shiny-module-data-sharing",
                           "qa-targets-pipeline", "wiki-frontmatter", "medical-etl-quality", "t-lang-r-package")
        )
      }),
      packages = c("tibble", "cli"),
      cue = tar_cue(mode = "always")
    ),

    # 9b. Rule categories caption — dynamic counts, never hand-typed
    tar_target(
      vig_cr_rules_caption,
      paste0(
        "Rule categories across ", sum(vig_cr_rule_categories$count),
        " config files in ", nrow(vig_cr_rule_categories), " categories"
      )
    ),

    # 10. Skill categories — parsed from MANIFEST.md
    tar_target(
      vig_cr_skill_categories,
      tryCatch({
        manifest_path <- path.expand("~/.claude/skills/MANIFEST.md")
        lines <- readLines(manifest_path, warn = FALSE)

        # Extract table rows (excluding header and separator)
        skill_rows <- grep("^\\|", lines, value = TRUE)
        skill_rows <- skill_rows[!grepl("^\\| Skill|^\\|---", skill_rows)]

        # Parse category from each row (3rd column)
        categories <- vapply(skill_rows, function(row) {
          parts <- strsplit(row, "\\|")[[1]]
          if (length(parts) >= 3) trimws(parts[3]) else NA_character_
        }, character(1), USE.NAMES = FALSE)

        # Count by category and add mandatory flag
        category_counts <- table(categories)
        tibble::tibble(
          category  = names(category_counts),
          count     = as.integer(category_counts),
          mandatory = category == "Mandatory"
        ) |>
          dplyr::arrange(dplyr::desc(mandatory), dplyr::desc(count))
      }, error = function(e) {
        cli::cli_warn("vig_cr_skill_categories fallback: {conditionMessage(e)}")
        tibble::tibble(
          category  = c("Mandatory", "R Package Dev", "Data & Analysis",
                       "Project Mgmt", "Shiny & Web", "Quarto & Docs",
                       "AI/LLM Tools", "Targets & Pipelines", "DevOps & CI",
                       "Prose Quality", "Specialized"),
          count     = c(10L, 12L, 11L, 9L, 8L, 7L, 5L, 4L, 3L, 1L, 1L),
          mandatory = c(TRUE, rep(FALSE, 10))
        )
      }),
      packages = c("tibble", "dplyr", "cli")
    ),

    # 10b. Skill categories caption — dynamic counts, never hand-typed
    tar_target(
      vig_cr_skills_caption,
      paste0(
        "Skill modules by domain (", sum(vig_cr_skill_categories$count),
        " total across ", nrow(vig_cr_skill_categories), " categories)"
      )
    ),

    # 11. Agent tiers — parse YAML frontmatter from ~/.claude/agents/*.md
    tar_target(
      vig_cr_agent_tiers,
      tryCatch({
        agent_files <- list.files("~/.claude/agents", pattern = "\\.md$", full.names = TRUE)
        parse_agent <- function(path) {
          lines  <- readLines(path, warn = FALSE)
          fm_end <- which(lines == "---")
          if (length(fm_end) < 2L) return(NULL)
          fm_lines <- lines[seq(fm_end[1L] + 1L, fm_end[2L] - 1L)]
          get_field <- function(key) {
            hit <- grep(paste0("^", key, ":"), fm_lines, value = TRUE)
            if (length(hit) == 0L) return(NA_character_)
            trimws(sub(paste0("^", key, ":\\s*"), "", hit[1L]), which = "both") |>
              gsub(pattern = '^"|"$', replacement = "")
          }
          tibble::tibble(
            agent       = get_field("name"),
            model       = get_field("model"),
            authority   = get_field("authority"),
            description = get_field("description")
          )
        }
        do.call(rbind, Filter(Negate(is.null), lapply(agent_files, parse_agent)))
      }, error = function(e) {
        cli::cli_warn("vig_cr_agent_tiers fallback: {conditionMessage(e)}")
        tibble::tibble(
          agent = NA_character_, model = NA_character_,
          authority = NA_character_, description = NA_character_
        )
      }),
      packages = c("tibble", "cli")
    ),

    # 11b. Agent tiers caption — dynamic counts, never hand-typed
    tar_target(
      vig_cr_agents_caption,
      paste0(
        "Agent model tiers and delegation triggers (",
        nrow(vig_cr_agent_tiers), " agents: ",
        sum(vig_cr_agent_tiers$model == "haiku", na.rm = TRUE), " haiku, ",
        sum(vig_cr_agent_tiers$model == "sonnet", na.rm = TRUE), " sonnet)"
      )
    ),

    # 12. Hook lifecycle — parsed from ~/.claude/settings.json
    tar_target(
      vig_cr_hook_lifecycle,
      tryCatch({
        settings_path <- path.expand("~/.claude/settings.json")
        settings <- jsonlite::read_json(settings_path, simplifyVector = FALSE)
        hooks_cfg <- settings$hooks
        if (is.null(hooks_cfg) || length(hooks_cfg) == 0L) {
          cli::cli_abort("No hooks configured in {settings_path}")
        }

        # Canonical Claude Code hook-lifecycle ordering (event name -> phase).
        # This is the real session lifecycle, not a fabricated value.
        phase_order_map <- c(
          SessionStart      = 1L,
          UserPromptSubmit  = 2L,
          PreToolUse        = 3L,
          PostToolUse       = 4L,
          PreCompact        = 5L,
          Stop              = 6L,
          PermissionRequest = 7L,
          Notification      = 8L
        )

        rows <- list()
        for (event_name in names(hooks_cfg)) {
          for (group in hooks_cfg[[event_name]]) {
            matcher <- if (is.null(group$matcher)) "" else group$matcher
            for (h in group$hooks) {
              cmd <- h$command
              if (is.null(cmd)) next
              # Only .sh script hooks; ignore inline commands (e.g. afplay sounds)
              m <- regmatches(cmd, regexpr("\\S+\\.sh", cmd))
              if (length(m) == 0L || !nzchar(m)) next
              rows[[length(rows) + 1L]] <- tibble::tibble(
                hook    = basename(m),
                event   = event_name,
                matcher = matcher
              )
            }
          }
        }

        if (length(rows) == 0L) {
          cli::cli_abort("No .sh hook scripts parsed from {settings_path}")
        }

        all_hooks <- dplyr::bind_rows(rows) |>
          dplyr::distinct() |>
          dplyr::mutate(phase_order = unname(phase_order_map[event])) |>
          dplyr::arrange(phase_order, event, hook)

        all_hooks[, c("hook", "event", "matcher", "phase_order")]
      }, error = function(e) {
        cli::cli_warn("vig_cr_hook_lifecycle fallback: {conditionMessage(e)}")
        # Full 28-row fallback mirrors a parse of ~/.claude/settings.json taken
        # 2026-07-20; used only if settings.json is missing or unparseable.
        tibble::tibble(
          hook = c(
            "session_init.sh", "context_survival.sh", "llmtelemetry_emit.sh",
            "context_survival.sh", "log_command_use.sh",
            "file_protection.sh", "worktree_symlink_guard.sh", "mermaid_dashboard_guard.sh",
            "destructive_fs_guard.sh", "destructive_api_guard.sh", "compound_command_guard.sh",
            "docs_qa_precommit.sh", "agent_push_guard.sh", "log_agent_run.sh", "log_agent_run.sh",
            "context_monitor.sh", "post_push_qa.sh", "gh_comment_provenance.sh",
            "wiki_health_onwrite.sh", "skill_quality_onwrite.sh", "log_agent_run.sh",
            "log_agent_run.sh", "log_skill_use.sh", "nix_gcroot_warm.sh",
            "llmtelemetry_emit.sh", "loop_continuation.sh", "session_stop.sh",
            "permission_request.sh"
          ),
          event = c(
            "SessionStart", "SessionStart", "SessionStart",
            "PreCompact", "UserPromptSubmit",
            "PreToolUse", "PreToolUse", "PreToolUse", "PreToolUse", "PreToolUse",
            "PreToolUse", "PreToolUse", "PreToolUse", "PreToolUse", "PreToolUse",
            "PostToolUse", "PostToolUse", "PostToolUse", "PostToolUse", "PostToolUse",
            "PostToolUse", "PostToolUse", "PostToolUse", "PostToolUse",
            "Stop", "Stop", "Stop",
            "PermissionRequest"
          ),
          matcher = c(
            "", "compact|resume", "",
            "", "",
            "Edit|Write", "Edit|Write", "Edit|Write", "Bash", "Bash",
            "Bash", "Bash", "Bash", "Agent", "Task",
            "Bash|Task", "Bash", "Bash", "Edit|Write", "Edit|Write",
            "Agent", "Task", "Skill", "Bash|Edit|Write",
            "", "", "",
            ""
          ),
          phase_order = c(
            1L, 1L, 1L,
            5L, 2L,
            3L, 3L, 3L, 3L, 3L, 3L, 3L, 3L, 3L, 3L,
            4L, 4L, 4L, 4L, 4L, 4L, 4L, 4L, 4L,
            6L, 6L, 6L,
            7L
          )
        )
      }),
      packages = c("tibble", "jsonlite", "dplyr", "cli")
    ),

    # 12b. Hook lifecycle caption — dynamic hook/event counts, never hand-typed
    tar_target(
      vig_cr_hooks_caption,
      paste0(
        nrow(vig_cr_hook_lifecycle), " hook scripts across ",
        length(unique(vig_cr_hook_lifecycle$event)),
        " of 8 lifecycle events, parsed from ~/.claude/settings.json"
      )
    ),

    # 12c. Slash commands — parsed from ~/.claude/commands/*.md
    tar_target(
      vig_cr_commands,
      tryCatch({
        cmd_dir   <- path.expand("~/.claude/commands")
        cmd_files <- list.files(cmd_dir, pattern = "\\.md$", full.names = TRUE)
        if (length(cmd_files) == 0L) {
          cli::cli_abort("No command files found in {cmd_dir}")
        }

        parse_command_file <- function(path) {
          lines        <- readLines(path, warn = FALSE)
          filename_cmd <- paste0("/", tools::file_path_sans_ext(basename(path)))

          # Each file's first heading is "# /<name> - <description>"; the one
          # documented exception (braindump.md) uses YAML frontmatter instead.
          heading_idx <- which(grepl("^# /", lines))[1]
          if (!is.na(heading_idx)) {
            m <- regmatches(
              lines[heading_idx],
              regexec("^# (/\\S+)\\s*-\\s*(.*)$", lines[heading_idx])
            )[[1]]
            if (length(m) == 3L) {
              heading_cmd <- m[2]
              description <- trimws(m[3])
            } else {
              heading_cmd <- filename_cmd
              description <- NA_character_
            }
          } else {
            heading_cmd <- filename_cmd
            description <- NA_character_
            if (isTRUE(lines[1] == "---")) {
              fm_end <- which(lines == "---")
              if (length(fm_end) >= 2L) {
                fm_lines  <- lines[seq(fm_end[1] + 1L, fm_end[2] - 1L)]
                desc_line <- fm_lines[grepl("^description:", fm_lines)][1]
                if (!is.na(desc_line)) {
                  description <- trimws(sub("^description:\\s*", "", desc_line))
                }
              }
            }
          }

          # alias: either the file's heading names a different command than
          # its filename (e.g. hi.md's heading says "/session-start"), or the
          # file declares an explicit "**Alias: `/xxx`**" line.
          alias <- NA_character_
          if (!identical(heading_cmd, filename_cmd)) {
            alias <- heading_cmd
          } else {
            alias_idx <- which(grepl("^\\*\\*Alias:", lines))[1]
            if (!is.na(alias_idx)) {
              am <- regmatches(
                lines[alias_idx],
                regexec("`(/[a-zA-Z0-9_-]+)`", lines[alias_idx])
              )[[1]]
              if (length(am) == 2L && !identical(am[2], filename_cmd)) {
                alias <- am[2]
              }
            }
          }

          tibble::tibble(command = filename_cmd, alias = alias, description = description)
        }

        rows <- lapply(cmd_files, function(p) {
          tryCatch(parse_command_file(p), error = function(e) {
            cli::cli_warn("Skipping {basename(p)}: {conditionMessage(e)}")
            NULL
          })
        })
        rows <- Filter(Negate(is.null), rows)
        if (length(rows) == 0L) {
          cli::cli_abort("No slash commands parsed from {cmd_dir}")
        }
        dplyr::bind_rows(rows) |> dplyr::arrange(command)
      }, error = function(e) {
        cli::cli_warn("vig_cr_commands fallback: {conditionMessage(e)}")
        # Current 14-file fallback taken 2026-07-20 from ~/.claude/commands/;
        # used only if the directory is missing or unparseable. No pruned
        # commands (/ctx-check, /pr-status, /cleanup, /wiki-health removed
        # 2026-07-08 per llm#750).
        tibble::tibble(
          command = c(
            "/braindump", "/bye", "/check", "/cleanup-worktrees", "/hi",
            "/issue-triage", "/new-issue", "/roborev", "/roborev-clear-backlog",
            "/roborev-setup", "/session-end", "/session-start", "/wiki-promote",
            "/write-alt-text"
          ),
          alias = c(
            NA_character_, "/session-end", NA_character_, NA_character_, "/session-start",
            NA_character_, NA_character_, NA_character_, NA_character_,
            NA_character_, "/bye", NA_character_, NA_character_,
            NA_character_
          ),
          description = c(
            "Process latest brain dump into a structured Claude Code prompt",
            "End Development Session",
            "Run R Package Checks + Code Sweep",
            "Triage Flagged Stale Worktrees",
            "Initialize Development Session",
            "List GitHub Issues by Difficulty",
            "Create GitHub Issue with Branch",
            "Toggle roborev auto code review",
            "Clear roborev Backlog for a Project",
            "Configure roborev for Current Project",
            "End Development Session",
            "Initialize Development Session",
            "Promote an Output into the Wiki",
            "Generate Alt Text for All Figures"
          )
        )
      }),
      packages = c("tibble", "dplyr", "cli")
    ),

    # 12d. Slash commands caption — dynamic count, never hand-typed
    tar_target(
      vig_cr_commands_caption,
      paste0(
        nrow(vig_cr_commands), " slash commands, parsed from ~/.claude/commands/"
      )
    ),

    # 13. Sample excerpts — first 15 lines of 3 representative files
    tar_target(
      vig_cr_sample_excerpts,
      tryCatch({
        read_head <- function(path, n = 15L) {
          if (!file.exists(path)) return(character(0))
          readLines(path, n = n, warn = FALSE)
        }
        list(
          rule    = read_head("~/.claude/rules/btw-timeouts.md"),
          agent   = read_head("~/.claude/agents/critic.md"),
          command = read_head("~/.claude/commands/check.md")
        )
      }, error = function(e) {
        cli::cli_warn("vig_cr_sample_excerpts fallback: {conditionMessage(e)}")
        list(rule = character(0), agent = character(0), command = character(0))
      }),
      packages = c("cli"),
      cue = tar_cue(mode = "always")
    )
  )
}
