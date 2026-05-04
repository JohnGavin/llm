# Template: jarl.toml for R projects

Copy to project root as `jarl.toml`. Adjust `ignore` list for project-specific needs.

## Prerequisite: jarl is laptop-local only (see llm#99)

jarl is **not** available in the project's nix shell or in GitHub Actions CI:

- nixpkgs only ships jarl 0.3.0, which fails to build (insta snapshot tests) and
  predates the rule set this template uses.
- Install manually on each developer laptop:
  1. Download release ≥ 0.5.0 from https://github.com/krlmlr/jarl/releases
  2. Place the binary at `/usr/local/bin/jarl` (`chmod +x`)
  3. Verify: `/usr/local/bin/jarl --version`
- `r_code_check.sh` auto-detects `/usr/local/bin/jarl` even inside nix shell
  (where `/usr/local/bin` is not on PATH).
- Without the binary, `r_code_check.sh` skips jarl checks silently. ast-grep
  still runs. CI does not enforce jarl rules — they are a developer-laptop gate
  until llm#99 is resolved.

## When to use

New R projects that use `r_code_check.sh` (called by `/check`) automatically get
jarl linting **on developer laptops where the binary is installed**. This config
file customises which rules apply.

## Template

```toml
[lint]
# quotes: disabled by default — strings containing embedded quotes need the other quote style
# Remove from ignore list if your project has no such strings
ignore = ["quotes"]

[lint.assignment]
# Enforce <- over = (R community convention)
operator = "<-"
```

## Rules commonly worth enabling (add to ignore to disable, remove to enable)

| Rule | What it catches | Enable when |
|------|----------------|-------------|
| `quotes` | Single vs double quote style | No strings with embedded quotes |
| `unreachable_code` | `if (FALSE) {}` blocks | Always (add `# jarl-ignore` to legitimate dev stubs) |
| `redundant_equals` | `x == TRUE` → `x` | Always |
| `nzchar` | `x == ""` → `!nzchar(x)` | Always |
| `fixed_regex` | `grepl(".", x)` → `grepl(".", x, fixed=TRUE)` | Always |

## Per-project notes

Add a comment block at the bottom of your `jarl.toml` explaining any project-specific
suppressions:

```toml
# Project-specific suppressions:
# quotes: plan_vignette_closeread.R uses Mermaid strings with embedded "
```
