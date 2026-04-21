---
description: Enforce one variable change per modelling experiment to maintain scientific rigour
paths:
  - "explorations/**"
  - "R/**/model*"
  - "R/**/predict*"
  - "R/**/fit*"
---
# Rule: Single-Change Experiment Discipline

## When This Applies

Any modelling experiment that changes data, features, hyperparameters, or model architecture. Does NOT apply to refactoring, bug fixes, or infrastructure changes.

## CRITICAL: One Change Per Experiment

Each experiment commit MUST change exactly ONE of:

| Category | Examples |
|----------|----------|
| Data | New data source, different filtering, train/test split |
| Features | Add/remove a predictor, transform a variable |
| Hyperparameters | Learning rate, regularisation, tree depth |
| Architecture | Model family, layer structure, ensemble method |
| Preprocessing | Scaling, imputation, encoding |

## Commit Format

```
experiment: [category] description

Baseline: [metric] = [value]
Change: [what was changed]
Result: [metric] = [new value] ([better/worse/same])
```

## Violations

- Changing data AND model in one commit — split into two experiments
- "Trying a bunch of things" without tracking — each change needs its own commit
- No baseline metric recorded — cannot assess if the change helped
