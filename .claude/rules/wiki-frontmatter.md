# Rule: Wiki Frontmatter Mandatory

## When This Applies
Every markdown file inside a `wiki/` directory in a knowledge base project.

## CRITICAL: Every Wiki File Starts With YAML Frontmatter

The frontmatter provides queryable metadata, lifecycle tracking, freshness
signalling, and cross-source consensus at the page level. Without it,
`/wiki-health` can't detect stale content, the search tools can't filter
by tag or status, and agents can't identify which files need refresh.

## Schema

```yaml
---
title: <string>                     # required
canonical_question: <string>        # required
status: active | stale | superseded # required
fresh_until: YYYY-MM-DD              # required
consensus_level: unanimous | strong | split | divergent | direct  # required
sources:                            # required, list of raw/ filenames
  - transcript-1.md
  - transcript-2.md
compiled_by: <model-id>             # should — e.g. claude-opus-4-6
compiled_on: YYYY-MM-DD             # should
tags: [list]                        # may
supersedes: <previous-filename>     # may
parent: <parent-topic>              # may
---
```

## Required Field Semantics

| Field | Purpose |
|---|---|
| `title` | Human-readable title. May differ from filename — use natural phrasing |
| `canonical_question` | The definitive question this page answers. Different phrasings must resolve here. Prevents duplicate pages for the same concept |
| `status` | `active` (current), `stale` (past `fresh_until`), `superseded` (replaced by a new version) |
| `fresh_until` | ISO date (YYYY-MM-DD). `/wiki-health` flags pages whose date has passed. Default 90 days from creation; rapidly-evolving topics use shorter windows |
| `consensus_level` | See `confidence-markers` rule for the 5-level scale |
| `sources` | List of raw/ filenames cited in the body. Must match the files in the `## Sources` section |

## Optional Field Semantics

| Field | Purpose |
|---|---|
| `compiled_by` | Claude version ID. Lets you identify pages compiled by older models that may need refresh |
| `compiled_on` | Last compilation date. Usually same as creation but updated on major rewrites |
| `tags` | Search/filter categorisation. Use lowercase kebab-case: `[commodity, futures, macquarie]` |
| `supersedes` | Filename of the previous version this replaces. Creates an auditable version chain |
| `parent` | Filename of the hierarchical parent topic. Enables tree-structured wikis |

## Fresh-until defaults by content type

| Content type | Default `fresh_until` |
|---|---|
| Market structure / regulation | 30-60 days |
| Strategy implementation details | 90 days |
| Historical / theoretical background | 1 year |
| Transcript summaries | 1 year (the source transcript doesn't change) |
| Cross-cutting comparisons | 90 days |

## Examples

### Strategy page with multiple sources

```yaml
---
title: Curve Carry
canonical_question: "How does commodity curve carry generate returns and when does it fail?"
status: active
fresh_until: 2026-07-09
consensus_level: strong
sources:
  - flirting-with-models-faheem-osman-commodity-qis.md
  - flirting-with-models-gerald-rushton-commodity-strategies.md
compiled_by: claude-opus-4-6
compiled_on: 2026-04-09
tags: [commodity, futures, qis, macquarie, roll-yield]
---
```

### Summary page with a single source

```yaml
---
title: "Summary — Faheem Osman: Commodity QIS"
canonical_question: "What is Faheem Osman's argument for commodity QIS as an under-appreciated return source?"
status: active
fresh_until: 2027-04-09
consensus_level: direct
sources:
  - flirting-with-models-faheem-osman-commodity-qis.md
compiled_by: claude-opus-4-6
compiled_on: 2026-04-09
tags: [summary, commodity, macquarie]
---
```

### Superseded version

```yaml
---
title: Curve Carry (v1)
canonical_question: "How does commodity curve carry generate returns?"
status: superseded
fresh_until: 2026-01-01
consensus_level: strong
sources:
  - early-transcript.md
supersedes: null
---
```

The replacing page (`curve-carry.md`) would have `supersedes: curve-carry-v1.md`.

## Enforcement

- T1 (on-write) hook: `wiki_health_onwrite.sh` checks for frontmatter presence
- T2 (pre-commit): validates required fields
- T3 (`/wiki-health`): full frontmatter validation + staleness check
- `critic` agent in wiki validation mode verifies frontmatter matches body

## What happens when `fresh_until` passes

1. `/wiki-health` flags the page
2. Claude (or user) decides one of:
   - **Keep**: re-validate against raw sources, extend `fresh_until`
   - **Update**: write new version with `supersedes:` pointing to old
   - **Supersede**: same as update but mark old as superseded
   - **Archive**: set `status: superseded` with no replacement

## Related Rules

- `provenance-mandatory` — `## Sources` section must match frontmatter `sources:`
- `confidence-markers` — inline markers and `consensus_level` field
- `raw-folder-readonly` — source integrity underlying the freshness check
