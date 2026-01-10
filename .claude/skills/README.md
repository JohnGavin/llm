# Claude Skills for R Development

This folder contains reusable Claude skills for R development with reproducible Nix environments.

## What are Skills?

Skills are composable, portable bundles of instructions and resources that Claude can use across different projects. They help maintain consistency and best practices across your work.

## Available Skills

### 🔧 nix-rix-r-environment

**Purpose**: Set up and work within reproducible R development environments using Nix and the rix R package.

**Use when**:
- Starting new R projects requiring reproducible environments
- Working with R packages needing specific versions
- Setting up CI/CD with Nix
- Executing R code in controlled environments
- Ensuring consistency between local and GitHub Actions environments

**Key concepts**:
- Use ONE persistent nix shell for all work (not new shells per command)
- Lock package versions for reproducibility
- Same environment locally and in CI/CD
- Version control nix configurations

**Key files**:
- `SKILL.md` - Complete nix/rix workflow and best practices

### 📦 r-package-workflow

**Purpose**: Complete workflow for R package development from issue creation to PR merge using R packages (gert, gh, usethis) instead of CLI commands.

**Use when**:
- Developing R packages with version control
- Following GitHub-based development workflow
- Need to ensure proper testing and documentation
- Want reproducible development logs

**Key files**:
- `SKILL.md` - Complete workflow steps and best practices
- `workflow-template.R` - Annotated script template for development tasks

### 🎯 targets-vignettes

**Purpose**: Use the targets package to pre-calculate all objects displayed in package vignettes, separating computation from presentation.

**Use when**:
- Creating vignettes with heavy computational requirements
- Building reproducible data analysis pipelines
- Want vignettes to build quickly without re-running expensive calculations
- Creating telemetry and project statistics vignettes

**Key files**:
- `SKILL.md` - Pipeline patterns and vignette integration

### 🌐 shinylive-quarto

**Purpose**: Deploy Shiny apps that run entirely in the browser using WebAssembly through Shinylive for R within Quarto documents.

**Use when**:
- Creating interactive R dashboards that run in the browser
- Building package vignettes with interactive Shiny components
- Deploying Shiny apps without server infrastructure
- Publishing interactive tutorials or demonstrations

**Key concepts**:
- GitHub Pages hosts the static dashboard HTML/JS files
- R-Universe compiles packages to WebAssembly binaries
- Browser loads dashboard from GitHub Pages, packages from R-Universe

**Key files**:
- `SKILL.md` - Complete WebAssembly workflow, R-Universe setup, and GitHub Pages deployment

### 📊 project-telemetry

**Purpose**: Implement comprehensive project telemetry, logging, and statistics tracking for R packages using the logger package and targets.

**Use when**:
- Setting up logging infrastructure for R packages
- Creating telemetry vignettes to document project statistics
- Tracking git history and development metrics
- Monitoring test coverage and package health

**Key files**:
- `SKILL.md` - Logging patterns and telemetry vignette creation

### 🚀 pkgdown-deployment

**Purpose**: Deploy R package documentation using pkgdown and GitHub Pages with a hybrid workflow (Nix for logic, Native R for deployment).

**Use when**:
- Deploying pkgdown sites from Nix-based R projects
- Encountering `Permission denied` errors with bslib in Nix CI
- Building vignettes that depend on targets pipeline data
- Setting up GitHub Actions for documentation deployment

**Key concepts**:
- Nix store is read-only, conflicts with bslib runtime copying
- Use Native R (`r-lib/actions`) for pkgdown build step
- "Data Snapshot" pattern for vignette data via `inst/extdata`
- Logic verified in Nix, presentation in Native R

**Key files**:
- `SKILL.md` - Complete hybrid deployment workflow

### 🔍 gemini-cli-codebase-analysis

**Purpose**: Use Gemini CLI to analyze large codebases or multiple files that exceed Claude's context limits, leveraging Gemini's massive context window.

**Use when**:
- Analyzing entire R package codebases
- Searching for patterns across many files
- Verifying implementation of features across codebase
- Understanding project-wide architecture
- Working with files totaling more than 100KB
- Planning large refactoring efforts

**Key concepts**:
- Gemini for **analysis and understanding** (read-only)
- Claude Code for **modifications and changes**
- Integration with ellmer R package for reproducible analysis
- Use `@` syntax to include files and directories

**Key files**:
- `SKILL.md` - Complete Gemini CLI workflow for R package analysis

## Skill Count

Currently **7 skills** available:
1. nix-rix-r-environment
2. r-package-workflow
3. targets-vignettes
4. shinylive-quarto
5. project-telemetry
6. pkgdown-deployment
7. gemini-cli-codebase-analysis

## How to Use Skills

### In Claude Code

Skills in the `.claude/skills/` folder are automatically available to Claude Code when working in this project directory.

**To invoke a skill:**
1. Simply reference the skill concept in your conversation (e.g., "set up a nix environment for R")
2. Claude will automatically use the skill knowledge
3. Skills are composable - you can use multiple skills together

### In Other Projects

**To reuse these skills:**

1. **Copy the entire folder** to your new project:
   ```bash
   cp -r /path/to/claude_rix/.claude/skills /path/to/new-project/.claude/
   ```

2. **Or copy individual skills**:
   ```bash
   mkdir -p /path/to/new-project/.claude/skills
   cp -r /path/to/claude_rix/.claude/skills/nix-rix-r-environment \
         /path/to/new-project/.claude/skills/
   ```

3. **Commit to git** so team members get them automatically:
   ```bash
   git add .claude/skills/
   git commit -m "Add Claude skills for R development"
   ```

## Skill Structure

Each skill is a folder containing:

```
skill-name/
├── SKILL.md              # Main documentation (required)
├── supporting-files.*    # Templates, examples, etc. (optional)
└── other-resources.*     # Any other helpful files (optional)
```

## Creating New Skills

To create a new skill:

1. Create a new folder in `.claude/skills/`
2. Add a `SKILL.md` file with:
   - Description
   - Purpose (when to use it)
   - How it works
   - Examples and patterns
   - Best practices
3. Add any supporting files (templates, scripts, etc.)
4. Document the skill in this README

## Best Practices

1. **Keep skills focused**: One clear purpose per skill
2. **Include examples**: Show concrete usage patterns
3. **Add templates**: Provide copy-paste starting points
4. **Document dependencies**: Note required tools/packages
5. **Version control**: Commit skills to share with team
6. **Test skills**: Verify they work in new projects

## Skill Compatibility

These skills are designed to work across:
- **Claude Code**: Desktop IDE integration
- **Claude.ai**: Web interface
- **Claude API**: Programmatic access

The same skill files work in all environments!

## Contributing

When adding or updating skills:

1. Follow the existing structure
2. Include clear examples
3. Test in a fresh project
4. Update this README
5. Commit with descriptive message

## Resources

- [Claude Skills Blog Post](https://claude.com/blog/skills)
- [Claude Code Documentation](https://code.claude.com/docs)
- [Example Skills Repository](https://github.com/anthropics/claude-skills)

## Questions?

Skills are a powerful way to codify best practices and share knowledge. Experiment with creating your own!
