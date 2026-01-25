# llm

This repository contains workflows, notes, and assets for reproducible R package / Quarto / Shinylive work (Nix + rix + GitHub Actions), plus related project materials.

## Documentation

The detailed documentation is published on the GitHub wiki:

- Wiki home: https://github.com/JohnGavin/llm/wiki

The repo also keeps “wiki source” Markdown in `WIKI_CONTENT/` so changes can be reviewed/versioned with code, then synced to the wiki.

### Wiki Pages (with in-repo sources)

<!-- BEGIN WIKI_CONTENT_DOCS -->
- **Deployment Strategy: Pkgdown & GitHub Pages (Hybrid Nix + Native R)**  
  Summary: This page documents the hybrid workflow used to build and deploy pkgdown/Quarto documentation to GitHub Pages while keeping core package logic reproducible in Nix.  
  Source: `WIKI_CONTENT/Deployment_Strategy_Pkgdown_GitHub_Pages.md`  
  Wiki: https://github.com/JohnGavin/llm/wiki/Deployment-Strategy-Pkgdown-GitHub-Pages
  Key section: https://github.com/JohnGavin/llm/wiki/Deployment-Strategy-Pkgdown-GitHub-Pages#executive-summary

- **Nix vs Native R: Quick Reference**  
  Summary: Quick Decision Guide: Choose the right environment for each CI/CD task  
  Source: `WIKI_CONTENT/Nix_Environment_Guide.md`  
  Wiki: https://github.com/JohnGavin/llm/wiki/Nix-Environment-Guide
  Key section: https://github.com/JohnGavin/llm/wiki/Nix-Environment-Guide#quick-decision-matrix

- **R-WASM Build Workflows for Interactive Vignettes**  
  Summary: This page describes a workflow for building R packages as WebAssembly (WASM) binaries for use in browser-based Shinylive vignettes. The goal is fast iteration (minutes) vs waiting for r-universe sync (hours).  
  Source: `WIKI_CONTENT/R_WASM_Build_Workflows.md`  
  Wiki: https://github.com/JohnGavin/llm/wiki/R-WASM-Build-Workflows
  Key section: https://github.com/JohnGavin/llm/wiki/R-WASM-Build-Workflows#problem-statement

- **GC Root Naming Examples**  
  Summary: Single GC root for shared development environment:  
  Source: `WIKI_CONTENT/Technical_Notes.md`  
  Wiki: https://github.com/JohnGavin/llm/wiki/Technical-Notes
  Key section: https://github.com/JohnGavin/llm/wiki/Technical-Notes#current-setup-recommended-

- **Reproducible R Package Development with Nix and rix**  
  Summary: Complete workflow for developing R packages with Nix, ensuring reproducibility and consistency between local development and GitHub Actions CI/CD  
  Source: `WIKI_CONTENT/Workflows_and_Best_Practices.md`  
  Wiki: https://github.com/JohnGavin/llm/wiki/Workflows-and-Best-Practices
  Key section: https://github.com/JohnGavin/llm/wiki/Workflows-and-Best-Practices#table-of-contents

<!-- END WIKI_CONTENT_DOCS -->

## Critical Agent Configuration Files

These files define global rules and behaviors for Claude and other AI agents:

- **`AGENTS.md`** - Master guide for R package development workflow
  - Mandatory 9-step workflow
  - Nix environment setup
  - Tool preferences and delegation rules

- **`NIX_RULES.md`** - Critical Nix environment rules
  - **#1 Rule: NEVER install packages inside Nix**
  - Explains why this breaks reproducibility
  - Shows correct workflow for adding packages

- **`.claude/`** - Claude-specific configuration
  - Skills, agents, hooks, and commands
  - Symlinked from individual projects to this central location

## Keeping The Wiki In Sync

The canonical Markdown sources live in `WIKI_CONTENT/` and are periodically synced into `llm.wiki.git` (the GitHub wiki repository).

Use `R/dev/wiki/sync_wiki.R` to automate the sync (clone wiki repo, copy pages, update wiki `Home.md`, and regenerate the `README.md` docs list).
