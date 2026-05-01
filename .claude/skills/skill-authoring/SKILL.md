---
name: skill-authoring
description: Checklist and template for creating new Claude Code skills — use when adding a skill, writing a skill, designing a new skill, or reviewing skill quality
---

# Skill Authoring Checklist

Use this checklist before creating or substantially editing any skill. Skills encode practices at the same speed whether good or bad — this gate ensures quality.

## Before Writing

1. **Need:** Why does this skill exist? What gap does it fill?
   - Check `MANIFEST.md` for overlap with existing skills
   - If >80% overlap with an existing skill, extend that skill instead

2. **Tier:** Is this infra (always-on) or workflow (invoked on demand)?
   - **infra:** Applied automatically to every task. Must be universal. Examples: quality-gates, adversarial-qa
   - **workflow:** Invoked for specific domains/tasks. Examples: dplyr-1.1-patterns, shiny-bslib

3. **Triggers:** Write >= 3 natural-language trigger phrases for the `description` field
   - Use action verbs: "create", "build", "implement", "debug", "configure"
   - Include the domain: "Shiny module", "targets pipeline", "Quarto dashboard"
   - Bad: "when you need help" (too vague)
   - Good: "use when building Shiny modules with cross-module data sharing"

## Writing the Skill

4. **Structure:** SKILL.md body should be 500-3000 words
   - If > 3000 words, move detail to `references/` subdirectory
   - Lead with the most common use case, not edge cases
   - Include at least one concrete before/after code example

5. **Forbidden patterns table:** What anti-patterns does this skill prevent?

   ```markdown
   | Pattern | Why wrong | Fix |
   |---------|-----------|-----|
   | ... | ... | ... |
   ```

6. **Verification:** How to test the skill works
   - What command or scenario triggers it?
   - What output proves it activated correctly?

## After Writing

7. **MANIFEST entry:** Add a row to `~/.claude/skills/MANIFEST.md`
   - Set maturity to `beta` for new skills
   - Set score to `pending` until first review
   - Set tier (infra/workflow) per step 2

8. **CLAUDE.md listing:** Add the skill to the appropriate category in `~/.claude/CLAUDE.md` under "Skills by Category"

9. **Review:** Have the `critic` agent review the skill:
   ```
   Agent(subagent_type="critic", prompt="Review skill at ~/.claude/skills/NEW_SKILL/SKILL.md for quality: trigger phrases, structure, examples, forbidden patterns table, overlap with existing skills")
   ```

## Quality Scoring

| Criterion | Points | Check |
|-----------|--------|-------|
| >= 3 trigger phrases in description | 20 | grep for action verbs |
| Before/after code example | 20 | at least 1 pair |
| Forbidden patterns table | 15 | at least 3 rows |
| Body length 500-3000 words | 15 | wc -w |
| References/ for detail > 3000 words | 10 | progressive disclosure |
| Verification section | 10 | how to test |
| MANIFEST entry added | 10 | row exists |

- **80+:** Ready for stable
- **60-79:** Acceptable as beta
- **< 60:** Needs rework before merging

## Template

```markdown
---
name: my-new-skill
description: Use when [scenario 1], [scenario 2], or [scenario 3]. Triggers: [keyword1], [keyword2], [keyword3].
---

# Skill Name

Brief description of what this skill enables and when to use it.

## When to Use

- Scenario 1
- Scenario 2

## Patterns

### Pattern 1: [Name]

**Before:**
```r
# problematic code
```

**After:**
```r
# improved code
```

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---------|-----------|-----|
| ... | ... | ... |

## Verification

Run: `[command]`
Expected: `[output]`
```
