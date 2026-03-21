# Rule: Medical Data Anonymization (Generic)

## When This Applies
Any project containing Protected Health Information (PHI) or medical data.

## CRITICAL
**NEVER push medical data to public/remote repositories without anonymization.**

## HIPAA Safe Harbor - 18 Identifiers to Remove/Generalize

| # | Identifier | Action |
|---|------------|--------|
| 1 | Names | Replace with "Patient" or initials |
| 2 | Geographic data (below state) | Remove street address, keep city/region |
| 3 | Dates (except year) | Keep year only, or use relative dates |
| 4 | Phone numbers | Pattern: `0\d{2,4}\s*\d{3,4}\s*\d{3,4}` → [REDACTED] |
| 5 | Fax numbers | → [REDACTED] |
| 6 | Email addresses | → patient@example.com |
| 7 | Social Security numbers | → [REDACTED] |
| 8 | Medical record numbers | Replace with fake number |
| 9 | Health plan beneficiary numbers | → [REDACTED] |
| 10 | Account numbers | → [REDACTED] |
| 11 | Certificate/license numbers | → [REDACTED] |
| 12 | Vehicle identifiers | → [REDACTED] |
| 13 | Device identifiers | → [REDACTED] |
| 14 | Web URLs | Remove or generalize |
| 15 | IP addresses | → [REDACTED] |
| 16 | Biometric identifiers | → [REDACTED] |
| 17 | Full-face photos | Remove entirely |
| 18 | Any unique identifying characteristic | Case-by-case |

## UK-Specific Patterns

| Type | Regex Pattern | Replace |
|------|---------------|---------|
| NHS Number | `\b\d{3}\s*\d{3}\s*\d{4}\b` | 000 000 0000 |
| UK Phone | `\b0\d{2,4}\s*\d{3,4}\s*\d{3,4}\b` | [PHONE REDACTED] |
| UK Postcode | `\b[A-Z]{1,2}\d{1,2}\s*\d[A-Z]{2}\b` | Keep first half only |

## Doctor Names
- Replace full names with initials + specialty
- Example: "Dr Neil Rabin" → "Dr NR (Haematologist)"
- Keep the specialty for clinical context

## Implementation Pattern

```r
# Generic anonymization function template
anonymize_medical_text <- function(text, patient_patterns, doctor_patterns) {
  result <- text

  # Apply patient-specific patterns (defined per project)
  for (pat in patient_patterns) {
    result <- gsub(pat$find, pat$replace, result, ignore.case = TRUE, perl = TRUE)
  }

  # Apply doctor patterns
  for (pat in doctor_patterns) {
    result <- gsub(pat$find, pat$replace, result, ignore.case = TRUE, perl = TRUE)
  }

  # Apply generic patterns (always)
  result <- gsub("\\b\\d{3}\\s*\\d{3}\\s*\\d{4}\\b", "000 000 0000", result)  # NHS
  result <- gsub("\\b0\\d{2,4}\\s*\\d{3,4}\\s*\\d{3,4}\\b", "[PHONE]", result)
  result <- gsub("[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}", "patient@example.com", result)

  result
}
```

## Automated PHI Detection (Two-Layer)

Run `~/.claude/scripts/phi_scan.sh` before every commit in medical data projects.

**Layer 1 — Regex patterns:** NHS numbers, UK phones, emails, postcodes, dates of birth, patient names (Mr/Mrs/Dr + Name). Skips code patterns (gsub, grep, regex definitions).

**Layer 2 — Statistical (Willison method):** Flags tokens >12 chars with abnormal vowel ratios + mixed digits. Catches API keys, encoded PHI, base64 data, and random identifiers that regex misses. Based on [simonw/research/string-redaction-library](https://github.com/simonw/research/tree/main/string-redaction-library).

| Severity | Meaning | Action |
|----------|---------|--------|
| HIGH | NHS number, phone, DOB in data | BLOCK commit — must redact |
| MEDIUM | Email, postcode, possible name | Review — may be test data or legitimate |
| LOW | High-entropy string | Review — may be API key, token, or encoded PHI |

### Integration Options

**Manual:** `~/.claude/scripts/phi_scan.sh path/to/file.R`

**Git pre-commit hook** (add to medical projects):
```bash
# .git/hooks/pre-commit
~/.claude/scripts/phi_scan.sh || exit 1
```

**Agent workflow:** Run before Step 4 (commit) of the 9-step workflow for any project with PHI.

## Project Setup Checklist

When starting a new medical data project:
1. [ ] Create project-local `.claude/rules/data-anonymization.md` with patient-specific patterns
2. [ ] Create `R/anonymize.R` with patient/doctor pattern lists
3. [ ] Add to `.gitignore`: any raw data with PHI
4. [ ] Run `phi_scan.sh` dry-run before any commit
5. [ ] Wire `phi_scan.sh` into git pre-commit hook
6. [ ] Use `git filter-repo` if PHI was ever committed

## References
- [HIPAA Safe Harbor](https://www.hhs.gov/hipaa/for-professionals/special-topics/de-identification/index.html)
- [UK Data Protection Act 2018](https://www.legislation.gov.uk/ukpga/2018/12/contents/enacted)
- [Willison string-redaction-library](https://github.com/simonw/research/tree/main/string-redaction-library) — statistical secret detection
