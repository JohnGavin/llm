---
paths: ["**/raw/**"]
---

# Rule: raw/ folder is append-only

## When This Applies
Any directory named `raw/` inside a knowledge base, wiki, or transcript collection.

## CRITICAL: Files in `raw/` MUST NOT Be Modified

`raw/` is the **source of truth**. Modifying existing files in `raw/` corrupts the
provenance chain and creates the "AI output saved back as input" feedback loop.

## What's Allowed

| Action | Allowed? |
|---|---|
| Write a NEW file in `raw/` | Yes |
| Read any file in `raw/` | Yes |
| Edit an EXISTING file in `raw/` | **No** — blocked by `file_protection.sh` hook |
| Rename a file in `raw/` | Only with explicit user confirmation |
| Delete a file in `raw/` | Only with explicit user confirmation + `safe-deletion` rule |

## Documented Exceptions

| Reason | How to handle |
|---|---|
| PHI / PII anonymisation | Use `R/anonymize.R`, save anonymised version as `raw/anonymized/<file>`, gitignore the original |
| Secret redaction | Same pattern — never edit in place |
| Truncation for size | Save truncated copy as `raw/excerpts/<file>`, keep original |
| Format conversion (e.g. PDF → md) | Save converted version with new filename, keep original |

## Why

Spisak's "second brain" post warns: *"When outputs get filed back, errors compound too."*
The fix is structural — make `raw/` physically append-only so AI cannot overwrite source material.

## Enforcement

The `file_protection.sh` hook blocks `Edit` operations on any path matching `*/raw/*`
where the file already exists. `Write` to a new file in `raw/` is allowed.

## Related Rules

- `provenance-mandatory` — wiki claims must cite raw files
- `confidence-markers` — distinguishes AI inference from source claims
- `safe-deletion` — confirmation before deleting >1MB files
