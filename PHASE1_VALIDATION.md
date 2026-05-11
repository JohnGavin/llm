# Phase 1 Validation Plan: Option 4 (Hybrid)

**Issue**: #137 Phase 1 validation
**Duration**: 2-3 weeks
**Strategy**: Retrospective analysis (Week 1) + Live usage tracking (Week 2-3)

## Week 1: Retrospective Analysis

### Step 1: Generate Candidate Skills from History

```bash
# Analyze last 20 sessions to extract workflows
~/.claude/scripts/skillify_backlog.sh 20
```

**What it does**:
- Scans last 20 session transcripts
- Runs `/skillify` on each to detect repeatable workflows
- Generates candidate skills in `~/.claude/skills/generated/`
- Creates report with workflow types and quality scores

**Expected output**:
- 10-15 candidate skills generated
- Success rate: ~50% (not all sessions have repeatable workflows)
- Report at: `~/.claude/skills/generated/backlog_report_YYYYMMDD_HHMMSS.md`

### Step 2: Review and Filter

```bash
# Read the report
cat ~/.claude/skills/generated/backlog_report_*.md | tail -1

# List generated skills
ls -la ~/.claude/skills/generated/
```

**Criteria**:
- Quality score ≥80 (production threshold)
- Non-duplicate (check workflow type distribution)
- Actually useful (would you use this?)

**Action**: Delete or archive low-quality/duplicate skills

### Step 3: Initial Promotion (Optional)

If any generated skills are immediately useful and score ≥80:

```bash
# Move to stable
mv ~/.claude/skills/generated/SESSIONID_SKILLNAME ~/.claude/skills/SKILLNAME

# Register in MANIFEST
echo "- skillname (Category: X, Tier: Y, Maturity: stable)" >> ~/.claude/skills/MANIFEST.md
```

---

## Week 2-3: Live Usage Tracking

### Step 4: Use Skills in Practice

During normal work over 2-3 weeks:
- Use generated skills when applicable
- Track usage via `skill_usage_tracker.sh log <skill_name>`
- Or: skills auto-log if they call the tracker

**How to invoke a skill**: Use the pattern/command documented in its SKILL.md

### Step 5: Monitor Usage Stats

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
# For each candidate:
# 1. Move to stable
mv ~/.claude/skills/generated/SESSIONID_SKILLNAME ~/.claude/skills/SKILLNAME

# 2. Update maturity in MANIFEST.md
# Change: "maturity: beta" → "maturity: stable"

# 3. Remove session ID prefix from directory name
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

## Tracking Commands Reference

| Command | Purpose |
|---------|---------|
| `skillify_backlog.sh [N]` | Generate skills from last N sessions |
| `skill_usage_tracker.sh log <name>` | Log a skill usage |
| `skill_usage_tracker.sh stats` | Show quick usage stats |
| `skill_usage_tracker.sh report` | Generate full usage report |

---

## Example Workflow

### Day 1 (Week 1)
```bash
cd ~/docs_gh/llm
~/.claude/scripts/skillify_backlog.sh 20
less ~/.claude/skills/generated/backlog_report_*.md
```

### Days 2-7 (Week 1)
- Review each generated skill
- Test 2-3 that look immediately useful
- Archive/delete obvious duplicates or low-quality ones

### Weeks 2-3
- Use generated skills during normal work
- Log usage: `skill_usage_tracker.sh log <skill_name>`
- Check stats periodically: `skill_usage_tracker.sh stats`

### End of Week 3
```bash
# Generate final report
skill_usage_tracker.sh report

# Promote skills with ≥3 uses and score ≥80
# Document in CHANGELOG.md
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
