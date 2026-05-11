# /skillify - Extract Skill from Conversation History

Analyze recent conversation history to identify repeatable patterns and automatically generate skill documentation.

## When to Use

- After completing a multi-step workflow you expect to repeat
- When you notice a pattern emerging across sessions
- To capture successful problem-solving sequences as reusable skills
- Before manually writing a skill (let skillify draft it first)

## Steps

1. Read last N tool calls from session transcript (default N=20)
2. Identify repeated operations and trigger phrases
3. Generate skill markdown with frontmatter
4. Register in MANIFEST.md
5. Run quality check (must score ≥80)
6. Report next steps for manual refinement

## Commands to Execute

```bash
# Default: analyze last 20 tool calls
~/.claude/commands/skillify.sh

# Custom: analyze last 30 tool calls
~/.claude/commands/skillify.sh 30

# Analyze last 50 tool calls
~/.claude/commands/skillify.sh 50
```

## Usage

User says one of:
- `/skillify` (default: 20 tool calls)
- `/skillify 30` (analyze last 30)
- "Extract this workflow as a skill"
- "Create a skill from this pattern"

## Output

The script will:
1. Analyze the conversation transcript
2. Identify workflow type (testing, git-workflow, nix-environment, etc.)
3. Extract repeated operations and trigger phrases
4. Generate `~/.claude/skills/<skill-name>/SKILL.md`
5. Add entry to `~/.claude/skills/MANIFEST.md`
6. Run quality check and report score
7. Provide next steps for manual refinement

## Next Steps After Generation

The generated skill is a DRAFT. You must:

1. **Review**: Edit `~/.claude/skills/<skill-name>/SKILL.md`
2. **Add examples**: Include before/after code snippets
3. **Add forbidden patterns**: Document common mistakes
4. **Add verification**: Describe how to test the skill
5. **Cross-reference**: Link to related skills/rules/commands
6. **Remove notes section**: Delete the "Notes" section when complete
7. **Update MANIFEST**: Change maturity from `beta` to `stable` when ready

## Related

- Skill: `skill-authoring` — Manual skill creation checklist
- Skill: `skillify` — This command's skill documentation
- Hook: `skill_quality_onwrite.sh` — Quality gate enforcement
