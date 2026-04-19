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
    )
  )
}
