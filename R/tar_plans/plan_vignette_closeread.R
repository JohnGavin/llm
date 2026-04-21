plan_vignette_closeread <- function() {
  list(
    # 1. Infrastructure counts from ~/.claude/
    tar_target(
      vig_cr_infra_counts,
      tryCatch({
        list(
          n_rules    = length(list.files("~/.claude/rules", pattern = "\\.md$")),
          n_skills   = length(list.files("~/.claude/skills", full.names = FALSE)),
          n_agents   = length(list.files("~/.claude/agents", pattern = "\\.md$")),
          n_hooks    = length(list.files("~/.claude/hooks", pattern = "\\.sh$")),
          n_commands = length(list.files("~/.claude/commands", pattern = "\\.md$")),
          n_memory   = length(list.files(
            "~/.claude/projects/-Users-johngavin-docs-gh-llm/memory",
            pattern = "\\.md$"
          ))
        )
      }, error = function(e) {
        cli::cli_warn("vig_cr_infra_counts fallback: {conditionMessage(e)}")
        list(
          n_rules = 58L, n_skills = 68L, n_agents = 12L,
          n_hooks = 7L, n_commands = 14L, n_memory = 14L
        )
      }),
      packages = c("cli"),
      cue = tar_cue(mode = "always")
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

    # 10. Skill categories — hardcoded from CLAUDE.md table (stable)
    tar_target(
      vig_cr_skill_categories,
      tryCatch({
        tibble::tibble(
          category  = c(
            "Mandatory", "R Package Dev", "Data & Analysis",
            "Targets & Pipelines", "Shiny & Web", "Quarto & Documentation",
            "Prose Quality", "DevOps & CI", "Project Management",
            "AI/LLM Tools", "Specialized"
          ),
          count     = c(8L, 15L, 10L, 4L, 8L, 6L, 1L, 3L, 8L, 5L, 1L),
          mandatory = c(TRUE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE)
        )
      }, error = function(e) {
        cli::cli_warn("vig_cr_skill_categories fallback: {conditionMessage(e)}")
        tibble::tibble(
          category  = "Unknown", count = 0L, mandatory = FALSE
        )
      }),
      packages = c("tibble", "cli")
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

    # 12. Hook lifecycle — hardcoded (stable)
    tar_target(
      vig_cr_hook_lifecycle,
      tibble::tibble(
        hook = c(
          "session_init.sh", "file_protection.sh", "context_survival.sh",
          "context_monitor.sh", "wiki_health_onwrite.sh", "session_stop.sh"
        ),
        event = c(
          "SessionStart", "PreToolUse:Edit|Write", "PreCompact+compact/resume",
          "PostToolUse:Bash|Task", "PostToolUse:Edit|Write", "Stop"
        ),
        phase_order = 1:6
      ),
      packages = c("tibble")
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
