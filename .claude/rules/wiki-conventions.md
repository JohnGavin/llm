---
description: Knowledge base wiki conventions — frontmatter, storage, provenance, confidence markers, glossary
paths:
  - "**/wiki/**"
  - "**/raw/**"
  - "**/knowledge/**"
---

# Rule: Wiki Conventions

Consolidated from: `wiki-frontmatter`, `wiki-storage-policy`, `wiki-staleness-check`, `raw-folder-readonly`, `provenance-mandatory`, `confidence-markers`, `glossary-management`.

---

## Part 1: Wiki Storage Policy

### Central Hub vs Per-Project

| Knowledge type | Location |
|---|---|
| Cross-project concepts (QIS, R patterns, stats) | `~/docs_gh/llm/knowledge/<domain>/` |
| Project-specific decisions | `<project>/wiki/` |
| Confidential/PHI | Per-project with `.gitignore` |

### Hub Structure

```
~/docs_gh/llm/knowledge/
├── PRIVATE               ← marker blocks push
├── <domain>/
│   ├── raw/              ← APPEND-ONLY
│   ├── wiki/             ← AI-maintained
│   └── outputs/          ← ephemeral
```

### Privacy: NEVER Push to GitHub

Enforced by:
1. `PRIVATE` marker file
2. `.git/hooks/pre-push` checks for marker
3. No remote configured

---

## Part 2: raw/ is Append-Only

### CRITICAL: Files in `raw/` MUST NOT Be Modified

| Action | Allowed? |
|---|---|
| Write NEW file | Yes |
| Read any file | Yes |
| Edit EXISTING file | **No** — blocked by hook |
| Rename/Delete | Only with user confirmation |

### Why

Modifying `raw/` corrupts provenance chain and creates "AI output → input" feedback loop.

---

## Part 3: Wiki Frontmatter (MANDATORY)

Every `wiki/*.md` file starts with:

```yaml
---
title: <string>                     # required
canonical_question: <string>        # required
status: active | stale | superseded # required
fresh_until: YYYY-MM-DD             # required
consensus_level: unanimous | strong | split | divergent | direct
sources:                            # required
  - transcript-1.md
compiled_by: orchestrator-tier        # should (do not hardcode model IDs — see auto-delegation rule)
compiled_on: YYYY-MM-DD             # should
tags: [list]                        # may
---
```

### Fresh-Until Defaults

| Content type | Default |
|---|---|
| Market structure | 30-60 days |
| Strategy details | 90 days |
| Historical/theoretical | 1 year |

---

## Part 4: Provenance (MANDATORY)

### Every Wiki File MUST Cite Sources

```markdown
The strategy works because hedgers are price-insensitive
([transcript.md:450](raw/transcript.md#L450)).
```

### Mandatory `## Sources` Section

Every `wiki/*.md` ends with:

```markdown
## Sources

- [file.md](../raw/file.md) — lines 715-795 (topic)
```

---

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

---

## Part 6: Staleness Check

After major sessions (>10 files, >3 vignettes, CI changes):

1. `/wiki-health` flags pages past `fresh_until`
2. Options: Keep, Update, Supersede, Archive

---

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

---

## Enforcement

| Tier | Mechanism |
|---|---|
| T1 | `wiki_health_onwrite.sh` — frontmatter + `## Sources` |
| T2 | Pre-commit validation |
| T3 | `/wiki-health` — full validation |

---

## Cross-Wiki Links

Use double-bracket syntax:

```markdown
See also [[congestion]] and [[commodity-vol-carry]].
```

---

## Related

- `knowledge-base-wiki` skill — full pattern documentation
- `/wiki-health` command — validation
