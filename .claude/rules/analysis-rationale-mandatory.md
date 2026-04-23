# Rule: Analysis Rationale Logging Is Mandatory

## Source

DSTT Ch13/14 (Turner). Gelman & Loken, "Garden of Forking Paths".
Enforces the `analysis-rationale-logging` skill.

## When This Applies

Any project with an `analysis/`, `explorations/`, or `vignettes/` directory that performs statistical analysis, model fitting, or data-driven decision-making.

## CRITICAL: Document WHY Before You See Results

Every analytical choice that could have gone differently MUST be logged before the results of that choice are observed. Retrospective rationalisation is easy and worthless. Prospective documentation is hard and valuable.

## Required Artefacts

### 1. Decision Log

Every analysis project MUST have `analysis/rationale/DECISIONS.md` (or equivalent) containing:

| Field | Required |
|-------|----------|
| Decision summary | What you chose |
| Date | When decided (absolute, not relative) |
| Category | cleaning / transform / model / subgroup / other |
| Alternatives considered | At least 2 alternatives with rejection reasons |
| Rationale | Why this choice over alternatives |
| Decided BEFORE seeing | What results were unknown at decision time |
| Decided AFTER seeing | What data prompted the decision |

### 2. Data Dictionary

Any dataset with coded, abbreviated, or non-obvious columns MUST have a data dictionary:

| Column | Required fields |
|--------|----------------|
| Each variable | Name, type, description |
| Coded values | Code → meaning mapping (e.g., `1 = Male, 2 = Female`) |
| Units | Where applicable |
| Source | Origin table/file |

Location: `data/data_dictionary.md` or inline in the analysis document.

## Decision Timing

| Phase | What to log |
|-------|-------------|
| Before EDA | Pre-registered hypotheses, planned analyses |
| During EDA | Outlier handling, transformation choices, variable selection |
| Before modelling | Model family choice, covariate selection, validation strategy |
| After modelling | Deviations from plan, sensitivity results, exploratory findings |

## Integration with targets

```r
# Log decisions as targets — creates audit trail in pipeline
tar_target(decision_outliers, {
  log_decision("Remove 3 outliers > $10M",
    category = "cleaning",
    rationale = "Confirmed data entry errors",
    decided_before = "regression coefficients")
})
```

## Forbidden Patterns

| Pattern | Why wrong |
|---------|-----------|
| Analysis with no decision log | No audit trail for forking paths |
| Log written after seeing all results | Retrospective rationalisation |
| "We chose X because it gave better results" | Resulting — judge process, not outcome |
| Single model reported without alternatives | Hidden forking paths |
| Coded variables without data dictionary | Uninterpretable by reviewers |

## Exemptions

| Context | Exempted from |
|---------|---------------|
| `explorations/` with score < 60 | Data dictionary (but decision log still required) |
| Quick one-off analyses (< 1 day) | Separate decision files (inline comments sufficient) |
| R package `R/` code (not analysis) | Entire rule — this is for analysis, not software |

## Review Integration

The `analytical-review-checklist` rule requires reviewers to check:
- Decision log exists and covers key choices
- Decisions were logged before results observed
- Alternatives were genuinely considered

## Related

- `analysis-rationale-logging` skill — templates and `log_decision()` function
- `analytical-review-checklist` rule — reviewers check for rationale
- `resulting-prohibition` rule — judge by process, not outcome
- `verification-before-completion` rule — evidence before claims
