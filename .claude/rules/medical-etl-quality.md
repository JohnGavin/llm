---
paths: ["**/etl*", "**/medical*", "**/lab_*"]
---

# Rule: Medical Data ETL Quality Standards

## When This Applies
Any ETL pipeline processing medical/lab data.

## CRITICAL: Never Discard Data

### NULL Values
- **NEVER** filter out records where `value IS NULL`
- NULL with comment = lab error, equipment failure, or pending result
- Store the reason WHY the value is missing
- Display as "NA" with the comment visible

### Censored Values (Below/Above Detection Limits)
| Pattern | Meaning | Action |
|---------|---------|--------|
| `<1.34` | Below detection limit | Extract 1.34, flag `is_censored = TRUE` |
| `>90` | Above measurement range | Extract 90, flag appropriately |
| `<X.XX Low` | Below limit + clinically low | Extract value, set flag = "L" |

### Lab Error Comments to Capture
| Pattern | Meaning |
|---------|---------|
| "Regret unable to analyse" | Sample processing failure |
| "Unable to calculate" | Calculation not possible (e.g., ratio with missing denominator) |
| "laboratory error" | General lab failure |
| "Please repeat" | Sample needs redrawn |
| "antigen excess" | Assay interference |

## Component Name Normalization

### Problem
Different hospitals/labs use different names for the same test:
- `free_lambda_light` vs `free_lambda_light_chains(uclh)`
- `calcium` vs `calcium_(albumin-adjusted)` (these ARE different tests)

### Solution
1. Create a normalization mapping in ETL
2. Document mappings in project memory file
3. Apply normalization BEFORE deduplication

### Detection Query
```sql
-- Find potential naming variants
SELECT component, COUNT(*) as n
FROM raw_observations
WHERE component LIKE '%(%'
   OR component LIKE '%_%_%'
GROUP BY component
ORDER BY component;
```

## Deduplication Strategy

When same (component, date) appears multiple times:
1. Prefer records WITH values over NULL/errors
2. Prefer latest download date
3. Prefer individual tests > profiles > combined panels
4. Log conflicts for review if values differ >5%

## Schema Requirements

Essential columns for medical ETL:
```sql
CREATE TABLE canonical_observations (
  component VARCHAR NOT NULL,
  measurement_date DATE NOT NULL,
  value DOUBLE,              -- NULL for lab errors
  value_display VARCHAR,     -- "NA", "<1.34", or actual value
  is_censored BOOLEAN,       -- TRUE if below/above detection
  censored_at DOUBLE,        -- The detection limit
  units VARCHAR,
  lower_range DOUBLE,        -- Reference range
  upper_range DOUBLE,
  flag VARCHAR,              -- H/L/NULL
  comment VARCHAR,           -- Lab error message
  source_test_names VARCHAR, -- Lineage
  PRIMARY KEY(component, measurement_date)
);
```

## Verification Checklist

Before considering ETL complete:
- [ ] No unexpected NULL values (check comments exist)
- [ ] Censored values extracted with thresholds
- [ ] Component names normalized (no hospital suffixes creating duplicates)
- [ ] Date ranges match source documents
- [ ] Lab errors preserved with comments
- [ ] Conflicts logged for review
