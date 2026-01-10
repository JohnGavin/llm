# Claude Skills Update - November 16, 2024

## Summary

Updated Claude skills based on instructions in `context.md` (the main project workflow guide). Added 2 new skills and updated the skills README.

## Changes Made

### New Skills Created

#### 1. nix-rix-r-environment
**Location:** `.claude/skills/nix-rix-r-environment/SKILL.md`

**Purpose:** Set up and work within reproducible R development environments using Nix and the rix R package.

**Key Topics Covered:**
- Using ONE persistent nix shell (not launching new shells per command)
- Creating nix environments with rix::rix()
- Verifying package availability in nix environment
- GitHub Actions integration with Nix
- Environment consistency between local and CI/CD
- Troubleshooting common nix issues
- Daily workflow best practices

**Why Added:** Referenced in README but didn't exist. Core requirement from context.md section 1 (Environment Setup).

---

#### 2. gemini-cli-codebase-analysis
**Location:** `.claude/skills/gemini-cli-codebase-analysis/SKILL.md`

**Purpose:** Use Gemini CLI to analyze large codebases that exceed Claude's context limits.

**Key Topics Covered:**
- When to use Gemini vs Claude
- `@` syntax for including files and directories
- R package codebase analysis patterns
- Integration with ellmer R package for reproducible analysis
- Combining with btw R package for code generation
- Architecture understanding and refactoring planning
- Logging Gemini analyses for reproducibility

**Why Added:** Explicitly mentioned in context.md section "Linking to LLMs" - "Using Gemini CLI for Large Codebase Analysis"

---

### Skills README Updated

**File:** `.claude/skills/README.md`

**Updates:**
1. Added skill count section (now 6 skills total)
2. Enhanced nix-rix-r-environment description with key concepts
3. Added gemini-cli-codebase-analysis to skills list
4. Listed all 6 skills explicitly:
   - nix-rix-r-environment
   - r-package-workflow
   - targets-vignettes
   - shinylive-quarto
   - project-telemetry
   - gemini-cli-codebase-analysis

---

## Skills Coverage Map

### Context.md Topics → Skills Mapping

| Context.md Section | Covered by Skill(s) |
|-------------------|---------------------|
| 1. Environment Setup | nix-rix-r-environment |
| 2. R Code Standards | r-package-workflow |
| 3. File Structure | r-package-workflow, targets-vignettes |
| 4. Targets Package | targets-vignettes |
| 5. Development Workflow | r-package-workflow |
| 6. Git Best Practices | r-package-workflow |
| 7. Bugs/Features/Issues | r-package-workflow |
| 8. GitHub Project Page | r-package-workflow |
| 9. GitHub Actions/Rix/Nix | nix-rix-r-environment, r-package-workflow |
| 10. Telemetry Statistics | project-telemetry, targets-vignettes |
| 11. Website (pkgdown) | r-package-workflow, targets-vignettes |
| r-shinylive dashboard | shinylive-quarto |
| Gemini CLI | gemini-cli-codebase-analysis |

---

## Context.md Topics Not Yet in Skills

Some specific tools mentioned in context.md but not yet full skills:
- **air R package** for code formatting (mentioned in section 2.3)
- **typst** for formula/text formatting (mentioned in section 2.3)
- **crew R package** for async workers (mentioned in random_walk project)
- **btw R package** for tidyverse code generation (mentioned briefly, covered in gemini skill)

These could be added as skills if they become central to the workflow, or can remain as tool references within existing skills.

---

## Existing Skills (Unchanged)

The following 4 skills were already complete and aligned with context.md:

1. **r-package-workflow** - Comprehensive R package development workflow
2. **targets-vignettes** - Using targets for vignette pre-calculation
3. **shinylive-quarto** - WebAssembly Shiny dashboard deployment
4. **project-telemetry** - Logging and telemetry tracking

---

## Verification

All skills are now present:

```bash
ls -la /Users/johngavin/docs_gh/claude_rix/.claude/skills/
# Shows 6 skill directories + README.md

find .claude/skills -name "SKILL.md" -type f
# Returns 6 SKILL.md files
```

---

## Next Steps (Optional)

If desired, could create additional focused skills for:

1. **air-code-formatting** - Using air package for R code formatting
2. **typst-documentation** - Using typst instead of LaTeX
3. **crew-async-workers** - Parallel processing with crew package

However, the core workflow from context.md is now fully covered by the 6 existing skills.

---

## How to Use These Skills

### In Claude Code
Skills are automatically available when working in this project directory.

Simply reference concepts in conversation:
- "Set up a nix environment for this R package"
- "Analyze this codebase with Gemini"
- "Create a telemetry vignette"
- "Deploy a Shinylive dashboard"

### In Other Projects
Copy the `.claude/skills/` folder to new projects:

```bash
cp -r /Users/johngavin/docs_gh/claude_rix/.claude/skills /path/to/new-project/.claude/
git add .claude/skills/
git commit -m "Add Claude skills for R development"
```

---

## Documentation

Each skill includes:
- Clear description and purpose
- When to use the skill
- How it works (with examples)
- Common patterns
- Best practices
- Integration with other skills
- Troubleshooting
- Resources and references

All skills follow consistent structure and markdown formatting.

---

## Alignment with context.md

The skills framework now fully implements the workflow described in `context.md`:

✅ Nix environment setup and verification
✅ R package development workflow
✅ Targets pipeline for vignettes
✅ Shinylive WebAssembly deployment
✅ Project telemetry and logging
✅ Gemini CLI for large codebase analysis

All core concepts from context.md are now captured as reusable, portable skills.
