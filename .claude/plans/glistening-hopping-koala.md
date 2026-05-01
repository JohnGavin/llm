# Plan: Fix 4 Skill Governance Gaps (from Hedgineer "Building for Agents" analysis)

## Context

Gap analysis of [The Art of Building for Agents (Hedgineer S3E1)](https://www.youtube.com/watch?v=wHt-_MZoeM8) vs our Claude Code setup identified 4 actionable gaps in skill governance. The video warns that skill proliferation becomes ungovernable without quality tracking, authoring checklists, tier separation, and automated validation. We have 63 skills with no manifest, no quality scores, no creation checklist, and no validation hook on skill writes.

## Approach: 4 incremental changes, each independently deployable

### 1. Skill Manifest (`~/.claude/skills/MANIFEST.md`)

**Problem:** 63 skills listed in CLAUDE.md categories but no central index with quality/maturity metadata. `session_init.sh` checks counts match but nothing more.

**Solution:** Create `MANIFEST.md` alongside CLAUDE.md with per-skill metadata:

```markdown
| Skill | Category | Tier | Maturity | Last Reviewed | Score |
|-------|----------|------|----------|---------------|-------|
| adversarial-qa | Mandatory | infra | stable | 2026-04 | 85 |
| quality-gates | Mandatory | infra | stable | 2026-04 | 80 |
| dplyr-1.1-patterns | R Package Dev | workflow | stable | 2026-03 | 75 |
```

- **Tier:** `infra` (always-on, mandatory) vs `workflow` (invoked on demand)
- **Maturity:** `stable` / `beta` / `experimental` / `deprecated`
- **Score:** 0-100 quality score (triggers, clarity, examples, coverage)
- **Last Reviewed:** date of last quality review

**Files to create/edit:**
- Create: `~/.claude/skills/MANIFEST.md`
- Edit: `~/.claude/scripts/agents_md_audit.sh` — add manifest drift check

### 2. Skill Authoring Checklist (new skill: `skill-authoring`)

**Problem:** Skills created ad hoc with no design gate. The video warns: "AI codifies practices at the same speed whether good or bad."

**Solution:** New skill at `~/.claude/skills/skill-authoring/` (modelled on `writing-plans`):

```yaml
---
name: skill-authoring
description: Checklist and template for creating new Claude Code skills — trigger phrases, progressive disclosure, quality gates
---
```

**Checklist content:**
1. **Need:** Why does this skill exist? What gap does it fill? Check MANIFEST for overlap.
2. **Triggers:** ≥3 natural-language trigger phrases in description
3. **Tier:** infra (always-on) or workflow (on-demand)?
4. **Structure:** Body 500-3000 words. Move detail to `references/` if >3000.
5. **Examples:** At least 1 concrete before/after code example
6. **Forbidden patterns:** Table of anti-patterns this skill prevents
7. **Verification:** How to test the skill works (command, expected output)
8. **MANIFEST:** Add entry with maturity=beta, score=pending

**Files to create:**
- `~/.claude/skills/skill-authoring/SKILL.md`

### 3. Infrastructure vs Workflow Tier Split

**Problem:** All 63 skills are flat — no distinction between always-on infrastructure skills and on-demand workflow skills. The video identifies this separation as critical for governance.

**Solution:** Add a `## Tier` column to the existing CLAUDE.md skills table and the new MANIFEST. Classification:

| Tier | Meaning | Count (est.) | Examples |
|------|---------|-------------|---------|
| `infra` | Always apply, never need invocation | ~15 | adversarial-qa, quality-gates, r-package-workflow, verification-before-completion |
| `workflow` | Invoked for specific tasks | ~48 | dplyr-1.1-patterns, shiny-bslib, quarto-dashboards, eda-workflow |

**Files to edit:**
- `~/.claude/CLAUDE.md` — add Tier column to skills table
- `~/.claude/skills/MANIFEST.md` — Tier column included in step 1

### 4. Critic Hook on Skill Writes

**Problem:** `critic` agent exists but isn't triggered when skills are created/edited. Wiki writes get T1 health checks via `wiki_health_onwrite.sh` — skills get nothing.

**Solution:** Add `skill_quality_onwrite.sh` as PostToolUse hook for Edit|Write on skill files:

```bash
# PostToolUse:Edit|Write matcher: "skills/"
# Checks (fast, <2s):
#   1. YAML frontmatter present (name, description required)
#   2. Description has ≥3 trigger verbs (create, add, build, implement, etc.)
#   3. Body has ## section headers (not a wall of text)
#   4. MANIFEST.md has matching entry (warn if missing)
# Exit 0 always (warn only, never block)
```

**Files to create/edit:**
- Create: `~/.claude/hooks/skill_quality_onwrite.sh`
- Edit: `~/.claude/settings.json` — add PostToolUse hook entry

## Execution Order

1. **MANIFEST.md** (step 1) — foundation for everything else
2. **Tier split** (step 3) — classify during manifest creation
3. **Skill authoring checklist** (step 2) — references the manifest
4. **Critic hook** (step 4) — validates against manifest

## Verification

1. Create MANIFEST.md → run `session_init.sh` → verify audit passes
2. Create a test skill → verify `skill-authoring` checklist guides the process
3. Edit a skill file → verify `skill_quality_onwrite.sh` fires and warns
4. Check CLAUDE.md tier column renders correctly

## Files Summary

| Action | File |
|--------|------|
| Create | `~/.claude/skills/MANIFEST.md` |
| Create | `~/.claude/skills/skill-authoring/SKILL.md` |
| Create | `~/.claude/hooks/skill_quality_onwrite.sh` |
| Edit | `~/.claude/CLAUDE.md` — add Tier column to skills table |
| Edit | `~/.claude/settings.json` — add PostToolUse hook |
| Edit | `~/.claude/scripts/agents_md_audit.sh` — add manifest drift check |
