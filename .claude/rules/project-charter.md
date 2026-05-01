---
paths:
  - "DESCRIPTION"
  - "README.qmd"
  - "README.md"
  - "vignettes/**"
  - "analysis/**"
---
# Rule: Project Charter and Scope Management

## When This Applies
Any analysis project or R package with an `analysis/` or `explorations/` directory. Especially relevant when scope grows beyond the original intent.

## CRITICAL: Define Scope Before Starting

Every project MUST have a charter (in README or a dedicated CHARTER.md) that answers:

1. **Question:** What specific question does this project answer?
2. **Boundary:** What is explicitly out of scope?
3. **Done:** What does "done" look like? What deliverable?
4. **Audience:** Who will use the output?
5. **Timeline:** When is this needed? (absolute date, not relative)

## Scope Creep Detection

| Signal | Action |
|--------|--------|
| "While we're at it, let's also..." | Stop. Check charter. File a separate issue. |
| New data source added mid-analysis | Does it serve the original question? If not, park it. |
| Third refactor of the same module | Ship what works, iterate later. |
| Analysis vignette > 500 lines | Split into focused sub-vignettes. |
| > 5 open issues on one project | Triage: which serve the charter? Close or defer the rest. |

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---------|-----------|-----|
| Starting analysis without a stated question | No way to know when you're done | Write the question first |
| "Explore everything" as a goal | Unbounded scope | Define 2-3 specific hypotheses |
| Adding features after "done" without new charter | Scope creep | New feature = new issue with rationale |
| No out-of-scope section | Everything becomes in scope | List 3+ things you will NOT do |
