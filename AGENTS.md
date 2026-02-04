# Agent Registry

This registry lists the specialized sub-agents available in the `.claude/agents/` directory. Use `delegate_to_agent` to invoke them.

| Agent Name | Role | Primary Focus |
| :--- | :--- | :--- |
| **[codebase_investigator](.claude/agents/reviewer.md)** | Architect | Analysis, refactoring, and system mapping. |
| **[data-engineer](.claude/agents/data-engineer.md)** | Pipeline Builder | SQL (DuckDB), dbt, and ETL architecture. |
| **[data-quality-guardian](.claude/agents/data-quality-guardian.md)** | QA Engineer | Data validation, contract enforcement, and anomaly detection. |
| **[targets-runner](.claude/agents/targets-runner.md)** | Orchestrator | Execution and debugging of `targets` pipelines. |
| **[r-debugger](.claude/agents/r-debugger.md)** | Troubleshooter | Fixing R runtime errors and package issues. |
| **[shinylive-builder](.claude/agents/shinylive-builder.md)** | UI Developer | Converting Shiny apps to WASM (Shinylive). |

## Delegation Guidelines

-   **Pipeline Failures?** $\rightarrow$ `targets-runner`
-   **Bad Data / Schema Changes?** $\rightarrow$ `data-quality-guardian`
-   **Slow SQL Queries?** $\rightarrow$ `data-engineer`
-   **Complex Refactors?** $\rightarrow$ `codebase_investigator`