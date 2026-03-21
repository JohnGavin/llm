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

### Scripts Location
- **Scanner:** `~/.claude/scripts/phi_scan.sh`
- **Hook:** `~/.claude/hooks/phi-scan-hook.sh`

### Layer 1: Known Patterns (Regex)
Fast, precise detection of known PHI formats:
- NHS numbers: `\b\d{3}\s*\d{3}\s*\d{4}\b`
- UK phones: `\b0\d{2,4}\s*\d{3,4}\s*\d{3,4}\b`
- UK mobiles: `\b07\d{3}\s*\d{6}\b`
- UK postcodes: `\b[A-Z]{1,2}\d[0-9A-Z]?\s*\d[A-Z]{2}\b`
- Emails: `[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}`
- Dates: UK (`\d{1,2}/\d{1,2}/\d{4}`) and ISO (`\d{4}-\d{2}-\d{2}`)
- MRN (8-digit): `\b\d{8}\b`

### Layer 2: Heuristic Detection
Uses `detect-secrets` (if installed) to catch:
- High-entropy strings (API keys, tokens)
- Base64-encoded data
- Unusual patterns that regex misses

Install: `pip install detect-secrets`

### Severity Levels

| Severity | Pattern | Action |
|----------|---------|--------|
| HIGH | NHS number, phone, MRN | BLOCK — must redact |
| MEDIUM | Email, postcode | Review — may be legitimate |
| LOW | High-entropy string | Review — may be API key |

### Usage

**Manual scan:**
```bash
~/.claude/scripts/phi_scan.sh /path/to/project
~/.claude/scripts/phi_scan.sh . --layer1-only      # Skip heuristics
~/.claude/scripts/phi_scan.sh . --json             # JSON output
~/.claude/scripts/phi_scan.sh . --patterns custom.txt  # Custom patterns
```

**Custom patterns file format** (one per line):
```
PATIENT_NAME:John\s+Gavin
HOSPITAL_NUM:21264224
```

**Git pre-commit hook:**
```bash
# .git/hooks/pre-commit
#!/bin/bash
~/.claude/scripts/phi_scan.sh . --layer1-only || {
  echo "PHI detected! Run 'source R/anonymize.R; anonymize_all_files()' first"
  exit 1
}
```

**Claude Code hook** (add to `.claude/settings.json`):
```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Write|Edit",
        "command": "~/.claude/hooks/phi-scan-hook.sh"
      }
    ]
  }
}
```

**Agent workflow:** Run before Step 4 (commit) in any project with PHI.

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
