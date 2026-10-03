---
paths:
  - ".claude/rules/credential-management.md"
---

# Companion: Credential and Data Governance

Supporting detail split out of the always-loaded [`credential-management`](../credential-management.md) rule (llm baseline trim, 2026-10-03).

## Moved from the `credential-management` rule body (2026-10-03, always-loaded baseline trim)

Verbatim text removed from the rule body to cut the always-loaded instruction baseline. The normative requirement is restated in the rule; this is the supporting detail.

### Safety-critical tier: scoping history (the 2026-08-11 leak)

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

### Required Pattern: R example

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

### Data Connection Hygiene: R examples

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

### Data Use Agreement checklist and HIPAA quick reference

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
