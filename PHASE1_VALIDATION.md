# Phase 1 Validation Plan: Option 3 (Progressive Real-Usage Capture)

**Issue**: #137 Phase 1 validation
**Duration**: 2-3 weeks
**Strategy**: Live usage capture during normal work (no retrospective analysis)

**Why Option 3**: Historical session transcripts contain no tool call data, making retrospective analysis (Option 4 Week 1) non-viable. Pivoting to progressive capture ensures organic skill generation from actual repeated workflows.

## Finding: No Historical Tool Call Data (Confirmed Limitation)

**Investigation (2026-05-11)**: Tested 15+ session transcripts in `~/.claude/projects/-Users-johngavin-docs-gh-llm/`:
- All transcripts return "Insufficient data" (<3 tool calls)
- `grep '"type":"tool_call_result"'` returns 0 matches in every transcript
- Transcripts are compacted summaries without detailed tool history

**Impact on skillify_backlog.sh**: The `skillify_backlog.sh [N]` command documented in earlier plans **does not scan N transcripts usefully** — it iterates over transcripts but every transcript returns "Insufficient data", so no skills are generated. This is a known architectural limitation, not a bug.

**Impact on PHASE1_VALIDATION.md claims**: References to `~/.claude/scripts/skillify_backlog.sh 20` generating skills from history were aspirational. The actual validation strategy is Option 3 (live capture), not Option 4 (retrospective).

**Future path**: Rewrite `skillify_backlog.sh` to read from `~/.claude/logs/unified.duckdb` once its tool-event schema is documented (tracking #137). Until then, the script is retained as a documented placeholder.

**Pivot**: Use Option 3 — generate skills live during Weeks 1-3 as patterns emerge naturally via `/skillify` within active sessions.

---

## Weeks 1-3: Progressive Skill Capture

### Step 1: Recognize Repeated Workflows

During normal work, notice when you repeat a workflow 2-3 times:
- Git PR workflow (branch → edit → commit → push → PR)
- Test-fix loop (test → fix → re-test)
- Nix environment regeneration
- Vignette render + validation
- Issue triage + close

**When you notice repetition**: Make a mental note or add a quick comment

### Step 2: Run `/skillify` When Pattern Emerges

```bash
# After completing a repeated workflow 2-3 times in one session
/skillify

# Or specify how many recent tool calls to analyze
/skillify 30
```

**What it does**:
- Analyzes last N tool calls from current session
- Detects repeatable patterns (6 workflow types)
- Generates skill markdown with frontmatter
- Auto-registers in MANIFEST.md
- Runs quality check

### Step 3: Log Usage Immediately

Right after generating a skill:

```bash
skill_usage_tracker.sh log <skill_name>
```

This starts tracking from the moment the skill is created.

### Step 4: Use and Track Generated Skills

Over the next 2-3 weeks:
- Use generated skills when the pattern recurs
- Log each use: `skill_usage_tracker.sh log <skill_name>`
- Or: skills can self-report if they call the tracker

### Step 5: Monitor Progress Weekly

```bash
# Quick stats
~/.claude/scripts/skill_usage_tracker.sh stats

# Full report
~/.claude/scripts/skill_usage_tracker.sh report
```

**Interpretation**:
- ≥3 uses = skill is genuinely useful
- ≥5 uses = strong candidate for stable promotion

### Step 6: Promote High-Usage Skills

At end of Week 3, promote skills that meet both criteria:
1. ≥3 uses (proven useful)
2. Quality score ≥80 (production quality)

```bash
# Generate final report
skill_usage_tracker.sh report

# For each candidate with ≥3 uses:
# 1. Verify it's already in ~/.claude/skills/ (skillify auto-places it there)
# 2. Update maturity in MANIFEST.md
# Change: "maturity: beta" → "maturity: stable"
# 3. Document in CHANGELOG.md
```

---

## Success Criteria (Phase 1 Complete)

| Criterion | Target | Status |
|-----------|--------|--------|
| Candidate skills generated | 10+ | [ ] |
| Skills promoted to stable | 3+ | [ ] |
| Quality threshold | ≥80 | [ ] |
| Usage threshold | ≥3 uses each | [ ] |
| Cross-modal eval tested | 5+ outputs | [ ] |
| Errors caught | 3+ issues | [ ] |

**Phase 1 is VALIDATED when**:
- ✓ 3+ skills promoted from beta to stable
- ✓ Each promoted skill has ≥3 real uses
- ✓ Cross-modal eval catches ≥3 real errors in outputs

---

## Commands Reference

| Command | Purpose |
|---------|---------|
| `/skillify [N]` | Extract skill from last N tool calls (default: 20) |
| `skill_usage_tracker.sh log <name>` | Log a skill usage |
| `skill_usage_tracker.sh stats` | Show quick usage stats |
| `skill_usage_tracker.sh report` | Generate full usage report |

---

## Example Workflow

### Week 1, Session 1
```bash
# Working on issue, notice git workflow repeated 3x
/skillify

# Output: "Generated: ~/.claude/skills/git-pr-workflow/SKILL.md"
# Quality score: 85

# Log the generation as first use
skill_usage_tracker.sh log git-pr-workflow
```

### Week 1, Session 3
```bash
# Use the skill again for another PR
# (follow pattern in SKILL.md)

# Log usage
skill_usage_tracker.sh log git-pr-workflow
```

### Week 2, Mid-week
```bash
# Check progress
skill_usage_tracker.sh stats

# Output:
# Total uses: 7
# Unique skills: 3
# Top skills:
#   3 uses: git-pr-workflow
#   2 uses: test-fix-loop
#   2 uses: vignette-render-check
```

### End of Week 3
```bash
# Generate final report
skill_usage_tracker.sh report

# Promote git-pr-workflow (3+ uses, score 85)
# Edit ~/.claude/skills/MANIFEST.md
# Change maturity: beta → stable
```

---

## Deduplication Strategy

Generated skills may overlap. Common patterns:

| Workflow Type | Expected Duplicates | How to Merge |
|---------------|---------------------|--------------|
| `git-workflow` | 3-5 variants | Keep most complete, archive others |
| `testing` | 2-4 variants | Merge into single test-driven-development update |
| `nix-environment` | 2-3 variants | Keep most recent (reflects current practices) |
| `r-execution` | 1-2 variants | Check if different enough to warrant separate skills |

**Rule**: If two skills have >70% overlap in implementation steps, merge into one.

---

## Fallback Plan

If Week 1 generates <10 skills or Week 2-3 shows <3 skills with ≥3 uses:

**Option A**: Extend live usage period to 4-5 weeks
**Option B**: Lower threshold to ≥2 uses (still validates usefulness)
**Option C**: Manually create 2-3 high-priority skills based on known pain points

---

## Next Phase Trigger

Phase 2 (Entity propagation, Book mirror, Meeting prep) begins when:
- Phase 1 validation complete (3+ stable skills in use)
- Cross-modal eval catches 3+ real errors
- User approves proceeding to Phase 2

Expected timeline: **Mid-June 2026** (3 weeks from Phase 1 merge on May 11)
