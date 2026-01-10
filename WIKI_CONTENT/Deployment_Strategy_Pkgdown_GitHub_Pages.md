# Deployment Strategy: Pkgdown & GitHub Pages (Hybrid Nix + Native R)

> **Note:** Detailed implementation has been moved to the Claude skill for better maintainability.
> See: [`.claude/skills/pkgdown-deployment/SKILL.md`](https://github.com/JohnGavin/llm/blob/main/.claude/skills/pkgdown-deployment/SKILL.md)

## Quick Summary

We use a **Hybrid Workflow**:

| Task | Environment | Why |
|------|-------------|-----|
| Core logic, tests, `devtools::check()` | **Nix** | Reproducibility |
| `pkgdown::build_site()` | **Native R** | Web tooling compatibility |
| Vignette computation | **Nix** (via targets) | Reproducible results |
| Vignette rendering | **Native R** | Uses pre-computed data |

## The Problem

The Nix store (`/nix/store/...`) is **read-only**, which conflicts with how `bslib` operates - it tries to copy JS/CSS assets at runtime, causing `Permission denied` errors.

## The Solution

Use `r-lib/actions` (Native R) for pkgdown deployment, while keeping core logic verification in Nix.

## Full Documentation

For complete implementation details including:
- GitHub Actions workflow configuration
- "Data Snapshot" pattern for vignettes
- Code examples and YAML templates
- Common errors and fixes

**See the skill file:** [`.claude/skills/pkgdown-deployment/SKILL.md`](https://github.com/JohnGavin/llm/blob/main/.claude/skills/pkgdown-deployment/SKILL.md)

## Related Resources

- [Nix Environment Skill](https://github.com/JohnGavin/llm/blob/main/.claude/skills/nix-rix-r-environment/SKILL.md)
- [R Package Workflow Skill](https://github.com/JohnGavin/llm/blob/main/.claude/skills/r-package-workflow/SKILL.md)
- [Targets Vignettes Skill](https://github.com/JohnGavin/llm/blob/main/.claude/skills/targets-vignettes/SKILL.md)
