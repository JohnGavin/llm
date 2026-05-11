---
name: skillify
description: Use when extracting repeatable patterns from conversation history to create new skills. Triggers: create skill from workflow, automate pattern, capture workflow as skill, analyze conversation for patterns.
---

# Skillify — Automate Skill Creation from Conversation History

Analyzes recent conversation transcripts to identify repeatable workflows and automatically generates skill documentation with proper frontmatter, quality checks, and manifest registration.

## When to Use

- After completing a multi-step workflow that you expect to repeat
- When you notice a pattern emerging across multiple sessions
- To capture tribal knowledge from successful problem-solving sequences
- Before manually writing a skill (let `skillify` draft it first)

## What It Does

1. **Analyzes transcript**: Reads the last N tool calls and messages from the current session
2. **Extracts patterns**: Identifies repeated operations, trigger phrases, and common parameters
3. **Generates skill**: Creates SKILL.md with frontmatter, examples, and forbidden patterns
4. **Validates quality**: Runs the skill quality check (requires score ≥80)
5. **Registers**: Adds entry to MANIFEST.md if not already present

## Usage

```bash
# Analyze last 20 tool calls (default)
/skillify

# Analyze last 30 tool calls
/skillify 30

# Analyze specific range
/skillify 50
```

## Pattern Extraction Logic

The script identifies:

1. **Triggers**: User messages that preceded the workflow
2. **Repeated operations**: Tool calls with similar patterns (same tool, similar params)
3. **Inputs**: Parameters that vary between invocations (these become skill inputs)
4. **Outputs**: Files created or modified (these become skill outputs)
5. **Sequence**: Ordered steps that form the workflow

## Generated Skill Structure

```markdown
---
name: extracted-pattern-name
description: [Trigger phrases extracted from user messages]
---

# Skill Name

[Generated description]

## When to Use

- [Scenario 1 from analysis]
- [Scenario 2 from analysis]

## Implementation

[Step-by-step commands extracted from tool calls]

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---------|-----------|-----|
| [Anti-patterns detected] | [Reasons] | [Fixes] |

## Verification

[Test commands extracted from sequence]
```

## Output Location

- Skill file: `~/.claude/skills/<skill-name>/SKILL.md`
- Manifest entry: `~/.claude/skills/MANIFEST.md` (auto-appended)
- Quality report: Inline summary with score

## Quality Gate

The generated skill must score ≥80 to be registered. If it scores lower:
- Review the generated content
- Add missing sections (examples, forbidden patterns, verification)
- Re-run quality check manually: `~/.claude/hooks/skill_quality_onwrite.sh ~/.claude/skills/<name>/SKILL.md`

## Example Workflow

**Scenario:** You just completed a 5-step workflow to debug a Nix shell issue:

1. User: "My nix-shell is broken, packages missing"
2. Agent: `Bash("echo $R_LIBS_SITE")`
3. Agent: `Bash("nix-store -qR ...")`
4. Agent: `Edit(default.nix, add shellHook)`
5. Agent: `Bash("nix-shell default.nix --run 'Rscript -e library(pkg)'")`

**Run:** `/skillify 10`

**Result:** Creates `~/.claude/skills/nix-shell-debug/SKILL.md` with:
- Trigger: "nix-shell broken, packages missing"
- Steps: Check R_LIBS_SITE → Inspect closure → Add shellHook → Verify
- Forbidden: Assuming --pure fixes it (doesn't keep environment)

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---------|-----------|-----|
| Running `/skillify` on trivial single commands | Wastes skill namespace | Only capture multi-step workflows (≥3 steps) |
| Accepting generated skill without review | May miss context or nuance | Always review and edit before committing |
| Creating skills for one-off problems | Pollutes skill catalog | Only skillify patterns you expect to repeat ≥3 times |
| Running on conversations with no clear pattern | Produces vague or incorrect skills | Look for repeated tool sequences first |

## Verification

After running `/skillify`:

1. Check skill created: `ls ~/.claude/skills/<name>/SKILL.md`
2. Verify manifest entry: `grep <name> ~/.claude/skills/MANIFEST.md`
3. Review quality score: Should see "Score: XX/100" in output
4. Test the skill: Invoke it in a new scenario

## Related

- Skill: `skill-authoring` — Manual skill creation checklist
- Command: `/skillify` — This command
- Hook: `skill_quality_onwrite.sh` — Quality gate enforcement
- Template: `~/.claude/templates/new-skill.md` — Manual skill template

## Limitations

- **Context dependent**: Skillify can't capture domain knowledge or rationale — add these manually
- **No meta-reasoning**: It extracts sequences, not "why" — you must add the "why" after
- **Over-generalizes**: May create skills that are too broad or too narrow — review carefully
- **Transcript only**: Only sees tool calls, not the full reasoning — claude's thinking is invisible

When skillify produces a low-quality draft, treat it as a starting point and manually refine per the `skill-authoring` checklist.
