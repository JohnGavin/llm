# CLAUDE.md ↔ .claude/agents/*.md Audit — Issue #236

**Date:** 2026-05-23
**Author:** fixer agent (claude-sonnet-4-6)
**Issue:** JohnGavin/llm#236

## Scope

Audit `~/.claude/CLAUDE.md` (global), `.claude/CLAUDE.md` (project), and each file in `.claude/agents/*.md` for:
- Agent information present in CLAUDE.md that is absent from the corresponding agent file (orphaned in CLAUDE.md)
- Agent information present in agent files that is absent from CLAUDE.md (orphaned in agent file)
- Contradictions between the two sources

## Files Audited

**CLAUDE.md sources:**
- `~/.claude/CLAUDE.md` — global config; `## Agents (12)` table at line 45–60; `auto-delegation` rule references
- `.claude/CLAUDE.md` (project) — `## Project-Specific Agents` section (lines 48–52)

**Agent files (12):**
`critic.md`, `data-engineer.md`, `data-quality-guardian.md`, `fixer.md`, `nix-env.md`, `quick-fix.md`, `r-debugger.md`, `reviewer.md`, `shiny-async-debugger.md`, `shinylive-builder.md`, `targets-runner.md`, `wiki-curator.md`

## Finding: No Orphans Found

CLAUDE.md and `.claude/agents/*.md` are coherent. Nothing needs to be relocated.

### Evidence

**Global CLAUDE.md agents table (lines 45–60):**

| Agent | Model | Use When |
|-------|-------|----------|
| `quick-fix` | haiku | Typos, renames, version bumps, obvious syntax fixes |
| `critic` | sonnet | Read-only adversarial review (cannot edit files) |
| `fixer` | sonnet | Apply fixes from critic reports (read-write, cannot self-approve) |
| `r-debugger` | sonnet | Debug R package issues (test failures, R CMD check) |
| `targets-runner` | sonnet | Run tar_make(), inspect pipeline state |
| `reviewer` | sonnet | Code review PRs for R package quality |
| `nix-env` | sonnet | Diagnose Nix shell problems, update deps |
| `shiny-async-debugger` | sonnet | Debug async/crew/ExtendedTask issues |
| `data-quality-guardian` | sonnet | Data validation, pointblank |
| `data-engineer` | sonnet | SQL transforms, dbt pipelines |
| `shinylive-builder` | sonnet | Build/test Shinylive WASM vignettes |
| `wiki-curator` | sonnet | Compile raw/ source material into wiki/ |

All 12 agents in this table have a corresponding file in `.claude/agents/`. No agent file is absent.

**Model consistency:**
Every agent file's YAML frontmatter `model:` field matches the CLAUDE.md table:
- `quick-fix.md`: `model: haiku` — matches
- All other agent files: `model: sonnet` — matches

**Role/description consistency:**
Each agent file's `description:` field in YAML frontmatter is consistent with the "Use When" column in CLAUDE.md, expressing the same scope in more detail. No contradictions.

**Authority fields:**
Every agent file has an `authority:` field in YAML frontmatter not present in CLAUDE.md. This is intentional — authority constraints (e.g., "CANNOT push", "CANNOT delete >1MB") live in the agent files, not in the CLAUDE.md summary table. This is the correct separation: CLAUDE.md is a routing table (when to use which agent), agent files are the full contract (what the agent can and cannot do).

**Project-specific agent overrides:**
`.claude/CLAUDE.md` (project level) lists two project-specific instructions:
- `targets-runner`: enter project shell first using the llm `default.nix` path
- `nix-env`: regenerate using the rix.setup shell

These are invocation overrides for this project, not agent definitions. They are correctly placed in the project CLAUDE.md rather than the agent files (agent files should be project-agnostic).

**Auto-delegation rule cross-reference:**
The `auto-delegation` rule (`.claude/rules/auto-delegation.md`) contains a trigger table mapping user request signals to agent names. All 12 agent names in that table match the agent files on disk. The `targets-runner` rule note "(wraps in `nix develop --command` for T lang projects)" is consistent with `targets-runner.md`'s T language section.

**No agents mentioned in CLAUDE.md but missing from `.claude/agents/`:**
No orphaned references found.

**No agent files without a CLAUDE.md entry:**
All 12 `.claude/agents/*.md` files appear in the CLAUDE.md table.

## Result

**Nothing to relocate. CLAUDE.md and `.claude/agents/*.md` are coherent.**

The two-file structure is working as designed:
- **CLAUDE.md**: routing table (name, model, brief trigger phrase)
- **`.claude/agents/*.md`**: full contract (role, workflow, constraints, output format, examples)

The article's `agents.md` pattern (a single flat file) is less structured than our approach. Our split is intentional and appropriate for 12 agents — a flat file would be harder to maintain and harder for the harness to consume selectively.
