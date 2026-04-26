# Rule: Strategy Name Consistency (Single Source of Truth)

## When This Applies

Any project with multiple named strategies, factors, or models that appear in tables, plots, captions, and prose across multiple vignettes.

## CRITICAL: One Target Defines All Names

Define a single target (e.g., `strategy_names`) that maps each strategy's:

- **code_name**: Variable-safe identifier used in code (`avoid_worst`, `drif`)
- **short_name**: Compact label for narrow columns and plots (`Avoid Worst`, `DRIF`)
- **long_name**: Full descriptive label for prose and wide tables (`Avoid Worst Days (VIX Protection)`, `DRIF (Factor Rotation)`)

Every table, plot, caption, and prose reference MUST pull from this target. No ad-hoc name construction.

## Display Rules

| Context | Which name | Example |
|---------|-----------|---------|
| Table column (wide) | long_name | "DRIF (Factor Rotation)" |
| Table column (narrow) | short_name | "DRIF" |
| Plot axis/legend | short_name | "DRIF" |
| Caption prose | long_name on first mention, short_name after | "DRIF (Factor Rotation) shows..." then "DRIF has..." |
| File output (CSV/parquet) | Both columns: code_name + long_name | `drif`, `DRIF (Factor Rotation)` |

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---------|-----------|-----|
| "LTR" in one tab, "LTR (CS Momentum)" in another | Inconsistent naming | Use short_name everywhere or long_name everywhere within a page |
| Caption says "Avoid Worst Days (VIX)" but table says "Avoid Worst" | Mismatch | Both use the same name from the target |
| Ad-hoc `c("Avoid Worst", "DRIF", ...)` in each target | Multiple sources of truth | Reference `strategy_names$short_name` |

## Source References in Captions (MANDATORY)

When a caption references a source file or function:

- **File**: Embed a GitHub link to the file at the current commit: `[plan_falsification.R](https://github.com/OWNER/REPO/blob/COMMIT/R/plan_falsification.R)`
- **Function**: Embed a link to the function's help page or source line: `[hd_hac_sharpe()](https://github.com/OWNER/REPO/blob/COMMIT/packages/pkg/R/falsification.R#L80)`
- **External data**: Link to the source: `[Ken French Data Library](https://mba.tuck.dartmouth.edu/pages/faculty/ken.french/data_library.html)`

Never leave bare function names like `hd_hac_sharpe()` or file names like `plan_falsification.R` without a link.

## Related

- `visualization-standards` — caption requirements
- `dynamic-prose-values` — no hardcoded values
- `acronym-expansion` — first-use expansion with links
