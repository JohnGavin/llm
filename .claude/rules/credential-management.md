---
name: credential-management
description: Never embed credentials in code; retrieve from environment, enforce small-number suppression, and manage data use agreements
type: rule
---

# Rule: Credential and Data Governance

## Source

DSTT Ch15 (Turner, dstt.stephenturner.us/governance.html).

## When This Applies

Any project that connects to databases, APIs, or external services, or that handles data subject to privacy requirements.

## CRITICAL: Never Embed Credentials in Code

A committed credential is a potentially exposed credential — even in private repos (forks, leaks, backup exposure).

## Credential Management

### Required Pattern

```r
# CORRECT: Retrieve from environment
con <- DBI::dbConnect(
  odbc::odbc(),
  server = Sys.getenv("DB_SERVER"),
  database = Sys.getenv("DB_NAME"),
  uid = Sys.getenv("DB_USER"),
  pwd = Sys.getenv("DB_PASSWORD")
)

# CORRECT: API keys from environment
httr2::req_auth_bearer_token(req, Sys.getenv("API_TOKEN"))
```

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

```r
# CORRECT: Always close connections, even on error
con <- DBI::dbConnect(...)
on.exit(DBI::dbDisconnect(con), add = TRUE)

# CORRECT: withr pattern
withr::with_db_connection(
  list(con = DBI::dbConnect(...)),
  { DBI::dbGetQuery(con, "SELECT ...") }
)
```

## Data Use Agreement Awareness

Before working with restricted data, verify:

- [ ] DUA obtained and reviewed
- [ ] Permitted uses cover your analysis
- [ ] Authorised users list is current
- [ ] Data environment requirements met (secure desktop, air-gapped, etc.)
- [ ] Dissemination restrictions understood (publication review, suppression)
- [ ] Data destruction requirements documented

## HIPAA Quick Reference (18 PHI Identifiers)

Names, geographic data finer than state, dates (except year), phone/fax numbers, email addresses, SSN, medical record numbers, health plan IDs, account numbers, certificate/license numbers, vehicle identifiers, device serial numbers, URLs, IP addresses, biometric identifiers, full-face photos, any unique identifying code.

**De-identification:** Remove all 18 identifiers (Safe Harbor) or obtain expert statistical determination of low re-identification risk.

**Minimum necessary:** Request only variables needed for analysis.

## Tier-based use (llm#376)

Not all credentials carry equal blast radius. The two-vault tier split in
`.claude/credential_tiers.toml` (gitignored; template at
`.claude/credential_tiers.toml.template`) classifies every environment
variable name into one of two tiers:

| Tier | Meaning | Agent behaviour |
|------|---------|-----------------|
| `[auto]` | Read-only keys, internal paths, low blast-radius | Agent may use without per-call human prompt |
| `[ask]` | Write-capable, billing, or high-value keys | Explicit human confirmation required per use |
| *(unlisted)* | Anything not categorised | Zero-trust default — treated as `[ask]` |

The `permission_request.sh` PreToolUse hook enforces these tiers. It scans
the command string for ALL_CAPS_WITH_UNDERSCORES patterns, looks each name
up in the TOML, and either approves silently (`[auto]`) or requires human
confirmation (`[ask]` or unknown).

**Setup:** copy the template and populate with your actual `.Renviron` key names:

```bash
cp .claude/credential_tiers.toml.template .claude/credential_tiers.toml
# Edit .claude/credential_tiers.toml — add key names only, never values
```

See `.claude/credential_tiers.README.md` for full setup instructions and the
self-test command.

### What belongs in `[auto]`

- Fine-grained read-only tokens (GitHub contents:read, issues:read)
- Internal filesystem paths (not secrets — just paths)
- Public read-only APIs where compromise grants only read access

### What belongs in `[ask]`

- Any key that can spend money (ANTHROPIC_API_KEY, OPENAI_API_KEY)
- Any key that can mutate external state (GITHUB_TOKEN, CACHIX_AUTH_TOKEN)
- Any key that can send external communications (NTFY_TOPIC)
- Production database credentials (DB_PASSWORD, DB_USER)
- Any key whose blast-radius you have not verified

### Forbidden patterns

| Pattern | Why wrong |
|---------|-----------|
| Putting billing keys in `[auto]` | Agent can incur costs without human knowledge |
| Committing the live `.toml` to git | Key names reveal what credentials exist |
| Leaving `[auto]` empty when read-only keys exist | Unnecessary friction for low-risk ops |
| Trusting `_READ_` suffix without verifying | Provider naming is not enforced |

## Related

- `.claude/credential_tiers.toml.template` — sample template
- `.claude/credential_tiers.README.md` — full setup guide
- `.claude/hooks/permission_request.sh` — tier enforcement hook
- `permission-discipline` rule — broader MCP and workspace permission rules
- `medical-data-anonymization` rule — PHI handling for medical projects
- `medical-etl-quality` rule — ETL quality for health data
- `duckdb-patterns` skill — DuckDB security hardening and duckplyr patterns
- `safe-deletion` rule — safe handling of sensitive files
