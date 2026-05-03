# Plan: Skill Directory Convention + Automated Audit

## Context

Two related changes prompted by the timesfm comparison and agentskills.io spec work:

1. **Skill directory structure** — TimesFM uses `examples/` alongside `references/` and `scripts/`. We have 0 skills with `examples/` but 31 with `references/` and 4 with `scripts/`. Need to document the convention.
2. **audit_skills.R is manual-only** — The R audit checks description quality, name compliance, gotchas, evals, but must be run manually. The session_init.sh shell audit only checks line counts.

## Approach

### 1. Document Skill Directory Convention

**File:** `.claude/skills/spec-bundled-skills.md` — add "Directory Structure Convention" section.

Convention:
```
skill-name/
  SKILL.md          # Required
  references/       # Optional — spec files, API docs
  scripts/          # Optional — executable helpers
  examples/         # Optional — runnable worked examples with output/
  evals/            # Optional — test cases for skill quality
```

**When to use `examples/`:** Multi-step workflows, output-generating skills, complex skills where inline examples are insufficient. NOT for simple pattern/convention skills.

**Do NOT adopt `assets/`** — too generic, overlaps with `references/`.

Also update `audit_skills.R` to report `has_examples` alongside other directories.

### 2. Automate audit_skills.R with Change Detection

**Strategy:** Timestamp-based — only run the R audit when skills have changed.

**New file:** `.claude/scripts/audit_skills_if_changed.sh`
- Uses `find -L ~/.claude/skills -newer $STAMP -print -quit` (~1ms when unchanged)
- If changed: runs `Rscript audit_skills.R`, touches stamp file
- If unchanged: prints "up to date", exits 0

**Wire into two places:**
- `.claude/hooks/session_stop.sh` — runs on every session stop, costs nothing when unchanged
- `.claude/commands/check.md` — runs full audit unconditionally (on-demand via `/check`)

**NOT in session_init.sh** — too slow (adds 2-3s R startup to already 5s hook).

## Files to Modify

| File | Change |
|------|--------|
| `.claude/scripts/audit_skills.R` | Add `has_examples` column |
| `.claude/scripts/audit_skills_if_changed.sh` | **New** — wrapper with change detection |
| `.claude/hooks/session_stop.sh` | Add conditional skill audit call |
| `.claude/commands/check.md` | Add skill audit step |
| `.claude/skills/spec-bundled-skills.md` | Add directory structure convention |

## Verification

1. Run `Rscript .claude/scripts/audit_skills.R` — should show `has_examples: 0/61`
2. Run `bash .claude/scripts/audit_skills_if_changed.sh` — first run: "changes detected", second run: "up to date"
3. Run `bash ~/.claude/hooks/session_stop.sh` — should include skill audit output
4. Check `/check` command includes skill audit section
