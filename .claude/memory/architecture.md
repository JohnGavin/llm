# Architecture & Two-Tier Nix Shell

## Two-Tier Nix Shell Architecture

Claude and agents operate in two layers:

| Shell | Purpose | Started By | Has Project Packages? |
|-------|---------|------------|----------------------|
| **Dev shell** | Generic R dev tools | `caffeinate -i ~/docs_gh/rix.setup/default.sh` | No - base tools only |
| **Project shell** | All DESCRIPTION packages | `nix-shell default.nix` in project root | Yes |

### How Agents Run Project-Specific Commands

Agents default to the dev shell. For project packages, use `nix-shell --run`:

```bash
cd /path/to/project
nix-shell default.nix --run "Rscript -e 'devtools::document()'"
nix-shell default.nix --run "Rscript -e 'devtools::test()'"
nix-shell default.nix --run "Rscript -e 'devtools::check()'"
```

**DO NOT use `./default.sh`** - it spawns an interactive shell agents cannot control.

### What Agents CAN Do

| Task | Method |
|------|--------|
| Edit/Read files | Direct tools (no R needed) |
| devtools::document/test/check | `nix-shell default.nix --run "..."` |
| Run targets pipeline | `nix-shell default.nix --run "Rscript -e 'targets::tar_make()'"` |
| Git operations | gert/Bash (gert is in dev shell) |
| Simple R code | btw tools (only if packages in dev shell) |

## Project-Specific Nix Environment Setup

Each project needs:
```
project/
├── default.R          # Generates default.nix from DESCRIPTION (rix())
├── default.sh         # Enters Nix shell with GC root
├── default.nix        # Generated Nix configuration
└── nix-shell-root     # Symlink to /nix/store (GC protection)
```

Exclude from git/R builds:
- `.gitignore`: nix-shell-root
- `.Rbuildignore`: ^nix-shell-root$, ^default\\.R$, ^default\\.nix$, ^default\\.sh$

Reference: millsratio/default.sh (simple), llm/default.sh (advanced)

## btw MCP Tool Configuration

Current subset (saves ~6k tokens): `btw::btw_tools(c('docs', 'pkg', 'files', 'run', 'env', 'session'))`

Excluded categories and alternatives:
- git → gert::git_*()
- github → gh::gh()
- agents → Task tool subagents
- cran → WebSearch
- web → WebFetch tool
- ide → rarely used

Re-enable: Edit ~/.claude.json mcpServers args

## Standard File Structure

```
R/                    # Package functions ONLY
├── *.R               # Analysis functions
├── dev/              # Development tools
│   └── issues/       # Fix scripts (MUST include in PRs)
└── tar_plans/        # Modular pipeline components
    └── plan_*.R      # Each returns list of tar_target()

_targets.R            # ONLY orchestrates plans from R/tar_plans/
vignettes/            # Quarto documentation
plans/                # PLAN_*.md working documents
README.qmd            # Source for README.md (NEVER edit directly)
```

## Key Conventions

- Never place target definitions in `_targets.R` directly — use `R/tar_plans/plan_*.R` modules
- README.qmd is source (never edit .md directly)
- Vignettes: ZERO computation — only `tar_load()`/`tar_read()` + display
- Use `DT::datatable()` only (never `knitr::kable()`)
