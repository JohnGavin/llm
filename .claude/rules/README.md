# Path-Scoped Rules for R Package Development

Rules in this directory are automatically loaded based on file patterns. Each rule file
specifies glob patterns that trigger the rules when editing matching files.

## How Rules Work

1. **Pattern Matching**: When you edit a file, Claude checks which rule files match
2. **Rule Loading**: Matching rules are loaded into context
3. **Guidance**: Rules provide specific guidance for that file type

## Rule Files

| File | Pattern | Purpose |
|------|---------|---------|
| `r-files.md` | `R/*.R` (excluding dev/, tar_plans/) | R source code standards |
| `test-files.md` | `tests/testthat/test-*.R` | Test file conventions |
| `quarto-files.md` | `*.qmd`, `*.Rmd` | Quarto/R Markdown rules |
| `nix-files.md` | `*.nix`, `default.R`, `default.sh` | Nix environment rules |
| `targets-plans.md` | `R/tar_plans/plan_*.R` | Targets pipeline rules |
| `github-workflows.md` | `.github/workflows/*.yml` | CI workflow rules |

## Integration with settings.json

Rules are configured in `~/.claude/settings.json`:

```json
{
  "rules": {
    "r-files": {
      "globs": ["R/*.R"],
      "excludeGlobs": ["R/dev/**", "R/tar_plans/**"]
    },
    "test-files": {
      "globs": ["tests/testthat/test-*.R"]
    },
    "quarto-files": {
      "globs": ["*.qmd", "*.Rmd", "vignettes/*.qmd"]
    },
    "nix-files": {
      "globs": ["*.nix", "default.R", "default.sh"]
    },
    "targets-plans": {
      "globs": ["R/tar_plans/plan_*.R"]
    },
    "github-workflows": {
      "globs": [".github/workflows/*.yml"]
    }
  }
}
```

## Adding New Rules

1. Create a new `.md` file in this directory
2. Add pattern matching configuration to settings.json
3. Document the rule in this README

## Principles

- **Specific over general**: Rules should be actionable, not abstract
- **Tidyverse aligned**: Follow tidyverse style guide
- **Defensive programming**: Validate inputs, fail fast with cli
- **Reproducibility**: Nix-first, targets pipelines
