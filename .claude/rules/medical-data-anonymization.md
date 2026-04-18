---
paths: ["**/anonymi*", "**/phi_*", "**/medical*", "**/patient*"]
---

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

Use `anonymize_medical_text()` with project-specific patient/doctor pattern lists and generic regex (NHS, phone, email). See project's `R/anonymize.R`.

## Automated PHI Detection (Two-Layer)

Two-layer scan: Layer 1 regex (NHS, phone, postcode, email, MRN, dates) + Layer 2 heuristic (`detect-secrets`). Scripts at `~/.claude/scripts/phi_scan.sh`. Severity: HIGH=block (NHS, phone, MRN), MEDIUM=review (email, postcode), LOW=review (high-entropy strings).

| Severity | Pattern | Action |
|----------|---------|--------|
| HIGH | NHS number, phone, MRN | BLOCK — must redact |
| MEDIUM | Email, postcode | Review — may be legitimate |
| LOW | High-entropy string | Review — may be API key |

Wire `phi_scan.sh` into git pre-commit hook (see Project Setup Checklist step 5).

## Container Isolation for PHI Processing (RECOMMENDED)

Process raw PHI in `docker run --network=none` container: read-only source mounts, writable output only. Prevents exfiltration even if code has bugs. Use for any script that reads raw patient data.

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
