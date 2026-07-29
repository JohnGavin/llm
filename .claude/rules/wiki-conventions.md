---
description: Knowledge base wiki conventions — frontmatter, storage, provenance, confidence markers, glossary
paths:
  - "**/wiki/**"
  - "**/raw/**"
  - "**/knowledge/**"
---

# Rule: Wiki Conventions

## Part 1: Wiki Storage Policy

### Central Hub vs Per-Project

| Knowledge type | Location |
|---|---|
| Cross-project concepts (QIS, R patterns, stats) | `~/docs_gh/llm/knowledge/<domain>/` |
| Project-specific decisions | `<project>/wiki/` |
| Confidential/PHI | Per-project with `.gitignore` |

See the companion doc for the Hub Structure directory diagram.

### Privacy: NEVER Push to GitHub

Enforced by:
1. `PRIVATE` marker file
2. `.git/hooks/pre-push` checks for marker
3. No remote configured

## Part 2: raw/ is Append-Only

### CRITICAL: Files in `raw/` MUST NOT Be Modified

| Action | Allowed? |
|---|---|
| Write NEW file | Yes |
| Read any file | Yes |
| Edit EXISTING file | **No** — blocked by hook |
| Rename/Delete | Only with user confirmation |

## Part 3: Wiki Frontmatter (MANDATORY)

Required fields and enum values (`status`, `consensus_level`) are validated
against `.claude/schema/wiki-frontmatter.schema.json` — the single source of
truth `wiki_health_check.sh` reads via `jq`. Update the schema file, not the
hardcoded lists in the script, when the frontmatter contract changes. Current
`consensus_level` enum: `unanimous | strong | split | divergent | direct`
(migration history from the interim `high | direct` vocabulary is in the
companion doc).

A worked `wiki/*.md` YAML frontmatter example is in the companion doc.

### Fresh-Until Defaults

| Content type | Default |
|---|---|
| Market structure | 30-60 days |
| Strategy details | 90 days |
| Historical/theoretical | 1 year |

### Exempt Pages (`<!-- wiki:exempt -->`)

Hub, index, and worksheet pages that are not themselves source-compiled
content (e.g. a topic-index page listing links, a scratch worksheet) do not
carry frontmatter or a `## Sources` section. Mark such a page by making its
**first line** exactly:

```
<!-- wiki:exempt -->
```

`wiki_health_check.sh` skips the frontmatter, provenance, staleness, and
lifecycle checks for exempt pages. The dead-`[[wiki-link]]` check still
runs — exemption is not a license for broken links. Full enforcement-scope
detail is in the companion doc.

## Part 4: Provenance (MANDATORY)

### Every Wiki File MUST Cite Sources; Every File Ends with `## Sources`

Worked examples for both are in the companion doc.

## Part 5: Confidence Markers

### Distinguish Source-Stated From AI-Inferred

| Marker | Meaning |
|---|---|
| (none) | Direct quote or close paraphrase |
| `> ⚠ AI-inferred:` | Synthesised across sources |
| `> 🔬 Hypothesis:` | Speculative |
| `> ❓ Conflicting:` | Sources disagree |

### Page-Level Consensus (Frontmatter)

| Level | Definition |
|---|---|
| `unanimous` | All sources agree |
| `strong` | Agree on core, differ on edges |
| `split` | Substantive divergence |
| `divergent` | Fundamentally different conclusions |
| `direct` | Single source / summary |

### Health Metric

Healthy: >70% source-stated, <20% AI-inferred, <5% each hypothesis/conflicting.

## Part 6: Staleness Check

After major sessions (>10 files, >3 vignettes, CI changes):

1. `wiki_health_check.sh <wiki_dir>` flags pages past `fresh_until`
2. Options: Keep, Update, Supersede, Archive

## Part 7: Glossary Management

### Required Columns

| Column | Description |
|---|---|
| Term | Term or acronym |
| Category | Domain category |
| Definition | With context |
| Appears_In | Vignette frequency |
| See_Also | External links |

### Requirements

- ALL acronyms in any vignette MUST appear
- Every term has at least one external link
- Sorted by frequency within category

## Enforcement

| Tier | Mechanism |
|---|---|
| T1 | `wiki_health_onwrite.sh` — frontmatter + `## Sources` |
| T2 | Pre-commit validation |
| T3 | `wiki_health_check.sh <wiki_dir>` — full validation (manual) |

## Cross-Wiki Links

Use double-bracket syntax. A worked example is in the companion doc.

## Related

- [`_companions/wiki-conventions-details.md`](_companions/wiki-conventions-details.md) — `consensus_level` migration history and exempt-page enforcement-scope detail
- `knowledge-base-wiki` skill — full pattern documentation
- `wiki_health_check.sh` — full validation script (T3)
