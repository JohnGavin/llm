# Reproducible R Package Development with Nix and rix

> **Note:** Detailed implementation has been moved to Claude skills for better maintainability.

## Quick Links to Skills

| Topic | Skill File |
|-------|------------|
| Nix/rix environment setup | [`.claude/skills/nix-rix-r-environment/SKILL.md`](https://github.com/JohnGavin/llm/blob/main/.claude/skills/nix-rix-r-environment/SKILL.md) |
| 9-step development workflow | [`.claude/skills/r-package-workflow/SKILL.md`](https://github.com/JohnGavin/llm/blob/main/.claude/skills/r-package-workflow/SKILL.md) |
| Pkgdown deployment | [`.claude/skills/pkgdown-deployment/SKILL.md`](https://github.com/JohnGavin/llm/blob/main/.claude/skills/pkgdown-deployment/SKILL.md) |
| Targets for vignettes | [`.claude/skills/targets-vignettes/SKILL.md`](https://github.com/JohnGavin/llm/blob/main/.claude/skills/targets-vignettes/SKILL.md) |

## Overview

### Goals

1. **Reproducibility**: Identical builds locally and in CI
2. **Consistency**: Same dependencies across all environments
3. **Simplicity**: Transparent workflow using R code
4. **Efficiency**: Fast CI via binary caches (no rebuilding)

### Key Technologies

- **Nix**: Reproducible package manager
- **rix**: R package for generating Nix expressions
- **Cachix**: Binary cache for pre-built packages
- **GitHub Actions**: CI/CD platform

## The Three-File Strategy

We use THREE nix files:

| File | Purpose |
|------|---------|
| `package.nix` | Package derivation (runtime deps only) |
| `default-ci.nix` | Complete dev environment (runtime + dev deps) |
| `default.nix` | Symlink to `default-ci.nix` |

See [nix-rix-r-environment skill](https://github.com/JohnGavin/llm/blob/main/.claude/skills/nix-rix-r-environment/SKILL.md) for details.

## The 9-Step Workflow

```
1. Create GitHub Issue (#123)
2. Create dev branch (usethis::pr_init())
3. Make changes locally
4. Run all checks (devtools::check(), etc.)
5. ⚠️ MANDATORY: Push to cachix
6. Push to GitHub (usethis::pr_push())
7. Wait for GitHub Actions
8. Merge PR (usethis::pr_merge_main())
9. Log everything (R/dev/issue/fix_issue_123.R)
```

See [r-package-workflow skill](https://github.com/JohnGavin/llm/blob/main/.claude/skills/r-package-workflow/SKILL.md) for complete details.

## Critical Rules

**NEVER use bash git/gh commands** - Always use R packages:
- ✅ `gert::git_add()`, `gert::git_commit()`, `gert::git_push()`
- ✅ `usethis::pr_init()`, `usethis::pr_push()`, `usethis::pr_merge_main()`
- ❌ `git add`, `git commit`, `git push` bash commands

**ALWAYS work in Nix environment:**
- Use ONE persistent shell per session
- Start with: `caffeinate -i ~/docs_gh/rix.setup/default.sh`

## Known Limitations

- **pkgdown with Quarto vignettes cannot work in Nix** due to read-only `/nix/store`
- Solution: Use [hybrid deployment strategy](https://github.com/JohnGavin/llm/blob/main/.claude/skills/pkgdown-deployment/SKILL.md)

## All Skills

View all available skills: [`.claude/skills/README.md`](https://github.com/JohnGavin/llm/blob/main/.claude/skills/README.md)
