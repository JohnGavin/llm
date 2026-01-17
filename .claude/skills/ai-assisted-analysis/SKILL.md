# AI-Assisted Statistical Analysis

## Description

Effective workflow for using LLMs (Claude, GPT, Gemini) as analysis collaborators while maintaining scientific rigor. Based on insights from Gelman's workflow discussion: AI handles execution well but humans must verify data understanding and validate assumptions.

## Purpose

Use this skill when:
- Using Claude/LLMs to execute statistical analyses
- Delegating code generation to AI while maintaining rigor
- Building reproducible AI-assisted workflows
- Verifying AI-generated analysis is trustworthy
- Integrating AI into existing R/targets pipelines

## Core Principle

From Dale Lehman's insight:

> "The AI does not specify the critical assumptions (that is left for the user to ask about, and adjust) or ask relevant questions about the data."

**AI excels at:** Execution, code generation, documentation, visualization
**Humans must do:** Data understanding, assumption validation, scientific judgment

## The AI-Assisted Workflow

```
┌─────────────────────────────────────────────────────────────────┐
│  1. HUMAN: EDA & Data Understanding                             │
│     └─→ Understand data before delegating                       │
│                                                                 │
│  2. HUMAN: Specify Analysis Goals                               │
│     └─→ Clear deliverables, not vague requests                  │
│                                                                 │
│  3. AI: Execute Analysis                                        │
│     └─→ Generate code, run models, create visualizations        │
│                                                                 │
│  4. HUMAN: Validate Data Handling                               │
│     └─→ Did AI understand the data correctly?                   │
│                                                                 │
│  5. HUMAN: Validate Assumptions                                 │
│     └─→ Are model assumptions appropriate?                      │
│                                                                 │
│  6. ITERATE: Prompt corrections based on validation             │
│     └─→ Each correction logged                                  │
│                                                                 │
│  7. HUMAN: Final interpretation                                 │
│     └─→ Scientific meaning, not just statistical output         │
└─────────────────────────────────────────────────────────────────┘
```

## Phase 1: Pre-AI Data Understanding

**Never delegate to AI before you understand the data yourself.**

```r
# YOU do this first, not AI
library(skimr)
library(visdat)

# 1. Structure check
glimpse(data)
skim(data)

# 2. Critical questions to answer BEFORE prompting AI:
# - What does each variable measure?
# - What's the unit of analysis (one row = what)?
# - Are there known data quality issues?
# - What domain knowledge constrains valid values?

# 3. Document your understanding
# analysis/00_data_understanding.md
```

**Why:** If you don't understand the data, you can't verify AI got it right.

## Phase 2: Effective Prompting

### Bad Prompts

```
# ❌ Too vague
"Analyze this data"

# ❌ No context
"Run a regression"

# ❌ Delegating judgment
"Tell me what model to use"
```

### Good Prompts

```
# ✅ Specific deliverables
"Fit a linear regression predicting log_income from education,
controlling for age and gender. Report coefficients with 95% CIs
and check residual assumptions."

# ✅ Context provided
"This is survey data on N=5000 adults. Income is right-skewed
and has been log-transformed. Education is years of schooling (0-20).
There are 3% missing values in income which I've already examined
and believe are MCAR."

# ✅ Explicit assumptions to check
"After fitting, check:
1. Residuals vs fitted plot for heteroscedasticity
2. Q-Q plot for normality of residuals
3. VIF for multicollinearity among predictors"
```

### Prompt Template for Analysis

```markdown
## Analysis Request

**Data:** [Brief description, N rows, key variables]
**Goal:** [Specific question to answer]
**Outcome variable:** [Name, type, any transformations applied]
**Predictors:** [Names, types, expected relationships]

**Known data issues I've already addressed:**
- [Issue 1]: [How handled]
- [Issue 2]: [How handled]

**Constraints:**
- [Domain knowledge constraints]
- [Required assumptions]

**Deliverables:**
1. [Specific output 1]
2. [Specific output 2]
3. [Diagnostic checks]

**Do NOT:**
- [Things to avoid]
```

## Phase 3: Validating AI Output

### Checklist: Did AI Understand the Data?

```r
# After AI generates analysis, verify:

# 1. Sample size matches expectations
# AI says N=4850, you expected 5000
# → Ask: "Why did 150 rows get dropped?"

# 2. Variable handling is correct
# AI treated categorical as numeric
# → Ask: "Education_level should be a factor with 4 levels, not numeric"

# 3. Missing data handled appropriately
# AI did complete case analysis without mentioning it
# → Ask: "How many rows were dropped due to missingness?
#         What's the missingness pattern?"

# 4. Transformations applied correctly
# You said log-transform, AI used raw values
# → Ask: "Please use log(income) as the outcome, not raw income"

# 5. Subsets/filters are correct
# AI included all ages, you wanted adults only
# → Ask: "Filter to age >= 18 before analysis"
```

### Checklist: Are Assumptions Validated?

```r
# AI provides regression output. Now verify:

# 1. Did AI check assumptions or just report results?
# If no diagnostics provided:
# → Ask: "Show residual diagnostics: residuals vs fitted,
#         Q-Q plot, scale-location plot"

# 2. Are assumption violations acknowledged?
# AI says "assumptions met" but residuals look heteroscedastic
# → Ask: "The residuals vs fitted plot shows increasing variance.
#         Should we use robust standard errors?"

# 3. Are there influential points?
# AI didn't check Cook's distance
# → Ask: "Check for influential points using Cook's distance.
#         Are any observations disproportionately affecting results?"
```

### Validation Questions to Always Ask

```markdown
After AI completes analysis, always ask:

1. "How many observations were used? Were any dropped and why?"

2. "What assumptions does this model make? Show diagnostics."

3. "Are there any outliers or influential points affecting results?"

4. "What happens to the main finding if we [sensitivity check]?"

5. "What are the limitations of this analysis?"
```

## Phase 4: Iteration Pattern

From Dale Lehman's experience:

> "Each time I point out one of these features, it then adapted its analysis, with all the attendant script, output, and interpretation of the changed results."

### Logging AI Iterations

```markdown
## AI Analysis Log: [Project Name]

### Session 1: Initial Analysis
**Prompt:** [Your prompt]
**AI Response:** [Summary of what AI did]
**Issue Identified:** [What was wrong/missing]

### Session 2: Correction 1
**Prompt:** "The outliers in income need to be addressed..."
**AI Response:** [How AI adapted]
**Issue Identified:** [Next problem]

### Session 3: Correction 2
**Prompt:** "The missing data pattern suggests MNAR, not MCAR..."
**AI Response:** [How AI adapted]
**Status:** Analysis now acceptable

### Final Validation
- [ ] Sample size verified
- [ ] All data issues addressed
- [ ] Assumptions checked
- [ ] Sensitivity analysis done
- [ ] Results reproducible from saved code
```

## Phase 5: Reproducibility

### The Reproducibility Problem

AI conversations are scattered across sessions. Code "works" because AI ran it, but:
- Was the exact prompt saved?
- Were all iterations captured?
- Can someone else reproduce this?

### Solution: Extract and Version

```r
# After AI generates working analysis:

# 1. Extract all code to a single script
# analysis/02_regression.R

# 2. Add header documenting AI involvement
#' ---
#' title: "Income Regression Analysis"
#' author: "[Your name], with AI assistance (Claude)"
#' date: "2026-01-08"
#' ai_sessions: 3 iterations to reach final version
#' key_corrections:
#'   - Session 2: Added outlier handling
#'   - Session 3: Switched to robust SE
#' ---

# 3. Run script independently to verify
source("analysis/02_regression.R")
# Must work without AI interaction

# 4. Commit to git
gert::git_add("analysis/02_regression.R")
gert::git_commit("Add regression analysis (AI-assisted, 3 iterations)")
```

### Integration with targets

```r
# _targets.R
library(targets)

# AI helped write this pipeline, but it's now:
# - Version controlled
# - Reproducible without AI
# - Documented

list(
  tar_target(raw_data, read_csv("data/survey.csv")),

  # AI-generated cleaning code, validated by human
  tar_target(clean_data, {
    raw_data |>
      filter(age >= 18) |>                    # Human specified
      filter(income < quantile(income, 0.99)) |>  # AI suggested, human approved
      mutate(log_income = log(income + 1))    # Human specified
  }),

  # AI-generated model, assumptions validated by human
  tar_target(model, {
    lm(log_income ~ education + age + gender, data = clean_data)
  }),

  # AI-generated diagnostics, interpreted by human
  tar_target(diagnostics, {
    performance::check_model(model)
  })
)
```

## AI Advice on Using AI

From Dale Lehman's conversation with AI about its own limitations:

> "Instead of expecting me to automatically learn from this experience, treat it like working with a talented but methodologically imperfect team member:
> 1. Set explicit standards at project start
> 2. Review process checkpoints rather than just outputs
> 3. Challenge assumptions before they become embedded
> 4. Require domain validation before deployment
> 5. Document lessons learned for future reference"

## Anti-Patterns

```markdown
# ❌ BLIND TRUST
AI: "The regression shows significant effect (p < 0.001)"
You: "Great, publish it!"

# ✅ VERIFY FIRST
You: "Show me the residual plots. How did you handle the 3 outliers
     I identified in EDA? What's the sample size after exclusions?"

# ❌ VAGUE DELEGATION
You: "Analyze this data and tell me what you find"
AI: [Runs 15 analyses, cherry-picks interesting one]

# ✅ SPECIFIC DELIVERABLES
You: "Test whether education predicts income, controlling for age.
     This is confirmatory—I pre-registered this hypothesis."

# ❌ SCATTERED WORKFLOW
Session 1: "Run regression" → Session 2: "Fix that" → Session 3: "Add this"
[No record of what changed or why]

# ✅ LOGGED ITERATIONS
[All prompts and corrections documented in analysis log]
[Final code extracted and versioned]

# ❌ AI AS ORACLE
You: "What model should I use?"
AI: "Use a mixed model"
You: "OK"

# ✅ AI AS EXECUTOR
You: "I believe a mixed model is appropriate because of clustering
     by region (ICC = 0.15). Please implement this and check
     the random effects structure."
```

## When NOT to Use AI

1. **Novel statistical methods** - AI knows common approaches, may hallucinate novel ones
2. **Critical domain decisions** - AI lacks your domain expertise
3. **Assumption validation** - AI will say "assumptions met" too readily
4. **Causal interpretation** - AI reports associations, humans infer causation
5. **Publication-ready prose** - AI writing is detectable and often generic

## Related Skills

- `eda-workflow` - Human EDA before AI delegation
- `analysis-rationale-logging` - Document why decisions were made
- `gemini-cli-codebase-analysis` - Using Gemini for code analysis
- `verification-before-completion` - Verify AI output before claiming done

## Resources

- [Gelman workflow discussion](https://statmodeling.stat.columbia.edu/2026/01/08/what-is-workflow-and-why-is-it-important/)
- [Claude Code documentation](https://docs.anthropic.com/claude/docs)
- [Will Marble on Claude Code](https://statmodeling.stat.columbia.edu/2026/01/08/what-is-workflow-and-why-is-it-important/#comment-2389941)
- [AI pair programming patterns](https://martinfowler.com/articles/ai-pair-programming.html)
