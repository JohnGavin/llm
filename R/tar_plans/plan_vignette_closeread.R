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
          n_memory   = length(list.files("~/.claude/projects/-Users-johngavin-docs-gh-llm/memory", pattern = "\\.md$"))
        )
      }, error = function(e) {
        cli::cli_warn("vig_cr_infra_counts fallback: {conditionMessage(e)}")
        list(n_rules = 57L, n_skills = 62L, n_agents = 12L, n_hooks = 8L, n_commands = 11L, n_memory = 8L)
      }),
      packages = c("cli"),
      cue = tar_cue(mode = "always")
    ),

    # 2. Software layer diagram (Section 1)
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

    # 3. Harness hub diagram (Section 2) — uses counts
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

    # 4. T-language DAG (Section 3) — embedded, no file dep
    tar_target(
      vig_cr_tlang_dag,
      paste0(
        'graph LR\n',
        '  good["good_val<br/>100 / 5 = 20"]\n',
        '  match["recovered_with_match<br/>match Error => 0"]\n',
        '  maybe["recovered_with_maybe_pipe<br/>?|> fallback -1"]\n',
        '  short["short_circuit_then_recover<br/>|> + ?|> fallback 0"]\n',
        '  risky["risky<br/>42 / 0 = Error"]\n',
        '  risky --> match\n  risky --> maybe\n  risky --> short\n',
        '  style good fill:#999999,stroke:#CC0000,color:#000000\n',
        '  style match fill:#999999,stroke:#CC0000,color:#000000\n',
        '  style maybe fill:#999999,stroke:#CC0000,color:#000000\n',
        '  style short fill:#999999,stroke:#CC0000,color:#000000\n',
        '  style risky fill:#999999,stroke:#CC0000,color:#000000\n',
        '  linkStyle default stroke:#CC0000,stroke-width:2px\n'
      )
    ),

    # 5. FOCUS flowchart (Section 4)
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

    # 6. Pipeline walkthrough data (Section 5)
    tar_target(
      vig_cr_pipeline_walkthrough,
      tibble::tibble(
        node = c("good_val", "recovered_with_match",
                 "recovered_with_maybe_pipe", "short_circuit_then_recover"),
        depends_on = c("(none)", "risky", "risky", "piped, risky"),
        layer = c("T runtime", "T runtime + error handler",
                  "T runtime + error handler", "T runtime + error handler"),
        pattern = c("Safe division", "match{} recovery",
                    "Maybe-pipe ?|>", "Pipe short-circuit + ?|>"),
        result = c("20", "0 (recovered)", "-1 (recovered)", "0 (recovered)")
      ),
      packages = c("tibble")
    ),

    # 7. Pipeline DAG mermaid with layer colours (Section 5)
    tar_target(
      vig_cr_pipeline_dag_mermaid,
      paste0(
        'graph LR\n',
        '  good["good_val<br/>Safe division<br/>Result: 20"]:::safe\n',
        '  risky["risky<br/>42 / 0"]:::error\n',
        '  match["match recovery<br/>Result: 0"]:::recover\n',
        '  maybe["?|> recovery<br/>Result: -1"]:::recover\n',
        '  short["short-circuit<br/>Result: 0"]:::recover\n',
        '  risky --> match\n  risky --> maybe\n  risky --> short\n',
        '  classDef safe fill:#999999,stroke:#CC0000,color:#000000\n',
        '  classDef error fill:#666666,stroke:#CC0000,color:#000000\n',
        '  classDef recover fill:#999999,stroke:#CC0000,color:#000000\n',
        '  linkStyle default stroke:#CC0000,stroke-width:2px\n'
      )
    ),

    # 8. Build info footer
    tar_target(
      vig_cr_build_info,
      {
        version <- tryCatch(as.character(utils::packageVersion("llm")), error = function(e) "dev")
        sha <- tryCatch(substr(gert::git_commit_info()$id, 1, 7), error = function(e) "unknown")
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
