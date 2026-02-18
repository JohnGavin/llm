# Orchestrator Protocol Skill

Structured workflow for autonomous task execution with human checkpoints.

## The Contractor Loop

```
┌─────────────────────────────────────────────────────────────────┐
│                     ORCHESTRATOR LOOP                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   PLAN ─────► IMPLEMENT ─────► VERIFY ─────► REVIEW              │
│     │                                           │                │
│     │         ┌─────────────────────────────────┘                │
│     │         │                                                  │
│     │         ▼                                                  │
│     │       FIX ─────► SCORE ─────► REPORT                       │
│     │         │                        │                         │
│     │         │    (loop if gate       │                         │
│     │         │     not passed)        │                         │
│     │         └────────────────────────┘                         │
│     │                                                            │
│     └──► Human checkpoint before first commit                    │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

## Configuration

```yaml
orchestrator:
  max_rounds: 3              # Maximum fix/verify cycles
  required_gate: silver      # bronze, silver, or gold
  auto_commit: false         # Require user approval for commits
  auto_push: false           # Require user approval for pushes
  abort_on_error: true       # Stop on unrecoverable errors
  parallel_verification: true # Run independent checks in parallel
```

## Phase Definitions

### Phase 1: PLAN

**Objective**: Understand task and create actionable plan.

**Steps**:
1. Parse user request
2. Read relevant files (explore codebase)
3. Create TodoWrite items
4. Identify dependencies and order

**Output**:
```markdown
## Task Plan

### Objective
[Clear statement of what will be accomplished]

### Steps
1. [ ] [Step 1]
2. [ ] [Step 2]
3. [ ] [Step 3]

### Files to Modify
- `R/function.R` - [Changes]
- `tests/testthat/test-function.R` - [Changes]

### Dependencies
- Step 2 depends on Step 1
- Step 3 can run parallel to Step 2
```

### Phase 2: IMPLEMENT

**Objective**: Execute the plan.

**Steps**:
1. Work through TodoWrite items
2. Edit files using Edit/Write tools
3. Mark items as completed
4. Document any deviations from plan

**Rules**:
- One logical change per commit
- Follow rules/ for file type
- No shortcuts (don't skip tests)

### Phase 3: VERIFY

**Objective**: Confirm implementation is correct.

**Agent**: Invoke `verifier` agent

**Checks (run in parallel where possible)**:
```python
# Parallel verification
Task(agent="verifier", model="haiku", prompt="Check DESCRIPTION valid"),
Task(agent="verifier", model="haiku", prompt="Check NAMESPACE current"),
Task(agent="verifier", model="sonnet", prompt="Run devtools::test()"),
Task(agent="verifier", model="sonnet", prompt="Run devtools::check()")
```

**Output**: Verification report with evidence

### Phase 4: REVIEW

**Objective**: Quality assessment.

**Agent**: Invoke `reviewer` agent (optional) OR apply quality gates

**Steps**:
1. Run quality gate assessment
2. Check gate level meets requirement
3. Identify issues to fix

**Output**:
```markdown
## Quality Gate: SILVER 🥈 (Score: 92.3)

### Metrics
- Coverage: 87% (target: 80%) ✓
- Check: 0 errors, 0 warnings, 1 note ✓
- Documentation: 95% ✓
- Lint: 3 style issues ⚠

### Issues to Address
1. [ ] Fix lint issues in R/analyze.R:23
```

### Phase 5: FIX

**Objective**: Address issues from verification/review.

**Steps**:
1. Prioritize issues by impact
2. Fix one issue at a time
3. Re-verify after each fix
4. Update TodoWrite

**Loop Control**:
- Maximum 3 rounds of fix/verify
- After 3 rounds, report and ask user

### Phase 6: SCORE

**Objective**: Final quality assessment.

**Steps**:
1. Run `assess_quality_gate()`
2. Compare to required gate
3. Determine if ready to proceed

**Decision**:
```
if (gate_passed) → REPORT (success)
if (rounds < max_rounds) → FIX (loop)
if (rounds >= max_rounds) → REPORT (blocked)
```

### Phase 7: REPORT

**Objective**: Summarize results for user.

**Success Report**:
```markdown
## Orchestration Complete ✓

### Summary
- Task: [Description]
- Duration: [Time]
- Rounds: [N]
- Gate: [Level] (Score: [X])

### Changes Made
1. Modified `R/analyze.R` - Added input validation
2. Added `tests/testthat/test-analyze.R` - 5 new tests
3. Updated documentation

### Verification
- Tests: PASS (47 passed, 0 failed)
- Check: PASS (0 errors, 0 warnings, 0 notes)
- Coverage: 89%

### Next Steps
- [ ] Review changes: `git diff`
- [ ] Commit: `gert::git_add(); gert::git_commit()`
- [ ] Push: `gert::git_push()`
```

**Blocked Report**:
```markdown
## Orchestration Blocked ⚠

### Summary
- Task: [Description]
- Rounds: 3/3 (max reached)
- Gate: Bronze (Score: 78) - Required: Silver

### Outstanding Issues
1. ✗ Test failure in test-analyze.R:45
   - Error: Expected 10 but got 9
   - Attempted fixes: [1, 2, 3]

2. ✗ Coverage at 75% (need 80%)
   - Uncovered: R/utils.R lines 23-45

### Recommendation
Manual intervention required. Consider:
- Simplifying test expectations
- Adding targeted tests for uncovered code
```

## Human Checkpoints

### Checkpoint 1: Before First Commit

```markdown
## Ready to Commit

### Changes Summary
- Modified 3 files
- Added 5 tests
- Updated documentation

### Quality Gate: Silver ✓

### Proceed?
[ ] Yes, commit these changes
[ ] No, I want to review first
[ ] Modify and re-verify
```

### Checkpoint 2: Before PR Creation

```markdown
## Ready to Create PR

### Branch: feature/add-validation
### Commits: 2

### Quality Gate: Silver ✓

### PR Summary
[Auto-generated summary]

### Proceed?
[ ] Yes, create PR
[ ] No, let me review
[ ] Add more changes first
```

## Parallel Agent Dispatch

### Pattern: Fan-out Verification

```python
# Launch independent checks in parallel
parallel_tasks = [
    Task(agent="verifier", model="haiku", prompt="Verify DESCRIPTION"),
    Task(agent="verifier", model="haiku", prompt="Verify NAMESPACE"),
    Task(agent="verifier", model="haiku", prompt="Check for lint issues"),
    Task(agent="verifier", model="sonnet", prompt="Run test suite"),
]

# All execute simultaneously
results = await asyncio.gather(*parallel_tasks)

# Sequential: depends on parallel results
if all(r.passed for r in results):
    await Task(agent="verifier", model="sonnet", prompt="Run R CMD check")
```

### Model Selection for Orchestration

| Task | Model | Rationale |
|------|-------|-----------|
| Parse task | haiku | Simple extraction |
| Read files | haiku | No reasoning needed |
| Create plan | sonnet | Moderate complexity |
| Edit code | sonnet | Requires understanding |
| Run tests | sonnet | Need to parse output |
| Complex debugging | opus | Deep reasoning |
| Architecture decisions | opus | High stakes |

## Recovery and Resume

### Abort Conditions

1. Unrecoverable error (e.g., package won't load)
2. User interrupt
3. Max rounds exceeded without progress
4. Blocking issue outside scope

### Resume Protocol

```
/orchestrate --continue

Resuming from: Phase 5 (FIX), Round 2/3

### Last State
- Issue: Test failure in test-analyze.R
- Attempted: Added edge case handling

### Continuing...
```

### State Persistence

```json
// .claude/orchestrator_state.json
{
  "task_id": "uuid",
  "task_description": "Add input validation",
  "current_phase": "FIX",
  "round": 2,
  "max_rounds": 3,
  "required_gate": "silver",
  "todos": [...],
  "verification_results": [...],
  "issues": [...]
}
```

## Integration with Other Components

### With Verifier
- Verifier provides evidence for VERIFY phase
- Verifier checklists guide what to check

### With Quality Gates
- Quality gates determine SCORE phase outcome
- Gate level controls when to proceed

### With Rules
- Rules load automatically based on files edited
- Rules guide IMPLEMENT phase

### With MEMORY.md
- Update session history at end
- Record decisions and lessons learned

## Usage

### Command Line
```
User: Add input validation to analyze_data function
Claude: [Enters orchestrator protocol]
```

### Manual Invocation
```
User: /orchestrate "Add input validation to analyze_data"
```

### Configuration Override
```
User: /orchestrate --gate=gold --max-rounds=5 "Critical fix for production"
```
