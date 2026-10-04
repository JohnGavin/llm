# Rule: Credential and Data Governance

## Safety-Critical Tier — Loads Unconditionally (No `paths:`)

Per [llm#943](https://github.com/JohnGavin/llm/issues/943), this rule is in the **safety-critical tier** declared in AGENTS.md and carries no `paths:` frontmatter, so it loads into every session and subagent; `check_rule_scoping.sh` fails (exit 3) if it regains `paths:` or is deleted. Scoping history: companion doc and `.claude/incidents/2026-08-11-credential-leak.md` §4.

## Source

DSTT Ch15 (Turner, dstt.stephenturner.us/governance.html).

## When This Applies

Any project that connects to databases, APIs, or external services, or that handles data subject to privacy requirements.

## CRITICAL: Never Embed Credentials in Code

A committed credential is a potentially exposed credential — even in private repos (forks, leaks, backup exposure).

## Credential Management

### Required Pattern

Retrieve secrets at runtime: `Sys.getenv("DB_PASSWORD")`, `httr2::req_auth_bearer_token(req, Sys.getenv("API_TOKEN"))`. Full DBI example: companion doc.

### Storage

| Method | When to use |
|--------|-------------|
| Project `.Renviron` | Project-specific credentials; MUST be in `.gitignore` |
| User `~/.Renviron` | Personal API keys shared across projects |
| `Sys.getenv()` | Retrieve at runtime |
| CI/CD secrets | GitHub Actions secrets, never in workflow YAML |

### Forbidden Patterns

| Pattern | Why wrong | Fix |
|---------|-----------|-----|
| `password = "hunter2"` in R code | Exposed in git history forever | `Sys.getenv("DB_PASSWORD")` |
| API key in committed `.R` file | Visible to anyone with repo access | `.Renviron` + `.gitignore` |
| Credentials in `_quarto.yml` | Committed to version control | Environment variable |
| `.Renviron` not in `.gitignore` | Credentials committed with project | Add `.Renviron` to `.gitignore` |
| `echo "${VAR:+yes}${VAR:-no}"` as an is-it-set check | **Prints the secret.** When `VAR` is set, `:+` yields `yes` and `:-` yields the *value* | `[ -n "${VAR:-}" ] && echo set \|\| echo unset` |
| Credentials in Docker image layers | Persist in image history | Multi-stage build or runtime env vars |

### Pre-commit Check

Before committing, verify no credentials are staged:

```bash
# Patterns that should never appear in committed code
git diff --cached | grep -iE '(password|secret|token|api_key)\s*=' && echo "STOP: credentials detected"
```

## Small Number Suppression

When publishing counts derived from individual-level data:

| Rule | Detail |
|------|--------|
| Minimum cell size | Suppress counts < 5 (display as `*` or "data not shown") |
| Complementary suppression | Suppress additional cells to prevent back-calculation |
| Derived statistics | Suppress rates/percentages computed from suppressed counts |
| Multi-dimensional | Check row totals, column totals, and cross-tabulations |
| User explanation | "Fewer than 5 events; suppressed to protect privacy" |

## Data Connection Hygiene

Always close connections, even on error (`on.exit(DBI::dbDisconnect(con), add = TRUE)` or `withr::with_db_connection()`).

## Data Use Agreement Awareness

Before working with restricted data verify: DUA obtained and reviewed; permitted uses cover the analysis; authorised-users list current; data-environment requirements met; dissemination restrictions understood; destruction requirements documented. Checklist: companion doc.

## HIPAA Quick Reference (18 PHI Identifiers)

Safe Harbor requires removing all 18 identifier classes (names, geography finer than state, dates except year, phone/fax, email, SSN, MRN, health-plan IDs, account/certificate/licence numbers, vehicle and device identifiers, URLs, IP addresses, biometrics, full-face photos, any unique code) or expert statistical determination. **Minimum necessary:** request only the variables needed. Full list: companion doc.

## Related

- `medical-data-anonymization` rule — PHI handling for medical projects
- `medical-etl-quality` rule — ETL quality for health data
- `duckdb-patterns` skill — DuckDB security hardening and duckplyr patterns
- `safe-deletion` rule — safe handling of sensitive files
