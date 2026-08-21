# Rule: Credential and Data Governance

## Safety-Critical Tier — Loads Unconditionally (No `paths:`)

This rule was scoped (`["**/.Renviron*", ".github/**", "R/**"]`) until
2026-08-12, which excluded every shell script, dotfile, secrets file and
launchd plist — i.e. everywhere secrets are actually handled. The forbidden
`${VAR:-...}` is-it-set construct documented below was consequently used
verbatim, printing a live key, one step in the chain that ended with 14
credentials published to a public repo. See
`.claude/incidents/2026-08-11-credential-leak.md` §4.

Widening the `paths:` list to cover shell/dotfile/plist surfaces was the
first fix, but it was still a scoped rule: a safety rule that only loads
where the risk has already materialised is not a safety rule. Per
[llm#943](https://github.com/JohnGavin/llm/issues/943), this rule is now in
the **safety-critical tier** declared in AGENTS.md's "Safety-critical rules"
line, alongside `external-code-zero-trust`, `permission-discipline`, and
`destructive-ops-guard` — it carries no `paths:` frontmatter at all and
loads into every session and every subagent, the same contract as the
mandatory tier. `check_rule_scoping.sh` enforces this: a safety-critical rule
that regains `paths:` frontmatter, or is deleted, fails the audit (exit 3)
and blocks the commit.

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

## Related

- `medical-data-anonymization` rule — PHI handling for medical projects
- `medical-etl-quality` rule — ETL quality for health data
- `duckdb-patterns` skill — DuckDB security hardening and duckplyr patterns
- `safe-deletion` rule — safe handling of sensitive files
