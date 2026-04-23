# Rule: Analytical Peer Review Checklist

## Source

DSTT Ch16 (Turner, dstt.stephenturner.us/peerreview.html).

## When This Applies

Any analysis producing findings that inform decisions — reports, dashboards, model outputs, or summaries shared beyond the analyst. This is distinct from code review (mechanical correctness) — analytical review asks whether the analysis answers the right question correctly.

## CRITICAL: Three Review Dimensions

Code review catches bugs. Analytical review catches wrong answers.

| Dimension | Question |
|-----------|----------|
| Code correctness | Does the implementation match the analyst's stated intent? |
| Method appropriateness | Does the analysis answer the intended question? |
| Conclusion validity | Do findings logically follow from results? |

## Required Checklist

### Data Section

- [ ] Data source correctly identified and loaded
- [ ] Date range and population scope match stated parameters
- [ ] Filters correctly specified and applied in correct order
- [ ] Missing values explicitly handled (not silently dropped)
- [ ] Join keys are unique, or duplicates are intentionally managed
- [ ] Row counts at key pipeline steps are plausible
- [ ] No filter inversions (`!=` where `==` intended, or vice versa)

### Analysis Section

- [ ] Numerators and denominators correctly specified for rates
- [ ] Denominator population matches numerator population
- [ ] Grouping variables match the stated analysis level
- [ ] Statistical methods appropriate for data structure and question
- [ ] Results align with prior domain knowledge (sanity check)
- [ ] Hard-coded values that should be computed are flagged

### Output Section

- [ ] Chart labels, titles, axis labels, and units are accurate
- [ ] Summary tables match code computations (spot-check 2-3 cells)
- [ ] Stated conclusions follow from the displayed results
- [ ] Uncertainty and limitations acknowledged
- [ ] Suppression rules applied where required (see `credential-management` rule)

## When to Escalate Review Rigor

| Trigger | Action |
|---------|--------|
| Results allocate resources or change programs | Independent replication by second analyst |
| Results released publicly or to press | Full checklist + independent replication |
| Unfamiliar method applied to this data | Method review by domain expert |
| Results contradict prior findings without obvious explanation | Root-cause investigation before release |

## AI as Review Supplement

**AI is useful for:**
- Explaining code in plain language
- Identifying common mechanical errors (filter inversions, implicit joins, type coercions)
- Checking variable name consistency

**AI is unreliable for:**
- Judging whether the method suits the question (requires domain knowledge)
- Detecting context-dependent errors (e.g., a jurisdiction stopped reporting in 2021)
- Evaluating whether conclusions are supported

Treat AI review comments as investigation starting points, not findings.

## Integration with Existing Workflow

| Existing tool | Role in analytical review |
|---------------|--------------------------|
| `critic` agent | Code-level review (mechanical) |
| `reviewer` agent | R package quality (structure) |
| This checklist | Analytical correctness (does the answer make sense?) |
| `quality-gates` skill | Numeric scoring at PR gates |

## Forbidden Patterns

| Pattern | Why wrong |
|---------|-----------|
| Merging analysis to main without any review | No error-catching opportunity |
| Reviewing only the code, not the outputs | Code can be correct but answer the wrong question |
| Skipping review because "it's just an update" | Updates introduce regressions |
| Treating AI review as sufficient | AI cannot judge domain appropriateness |

## Related

- `code-review-workflow` skill — PR-level code review process
- `quality-gates` skill — numeric scoring
- `verification-before-completion` rule — verify claims before stating them
- `statistical-reporting` rule — how to report metrics
