---
name: knowledge-base-wiki
description: Use when building a personal or project knowledge base from raw source material (transcripts, articles, notes, screenshots) into an AI-compiled wiki. Triggers - knowledge base, second brain, wiki, transcript collection, raw/wiki/outputs folder pattern, Karpathy second brain, source material organisation.
---

# Knowledge Base Wiki

A discipline for building auditable knowledge bases from raw source material,
addressing the four critical gaps in Karpathy's "second brain" / Spisak's
walkthrough: provenance, versioning, validation, confidence tracking.

## Core Pattern

```
<domain>/
├── raw/        — source material (transcripts, articles, screenshots)
│                 APPEND-ONLY (enforced by file_protection.sh hook)
├── wiki/       — AI-compiled organised wiki
│                 AI maintains; mandatory YAML frontmatter + ## Sources
│   ├── INDEX.md  — content catalog (per-topic one-liners)
│   └── LOG.md    — append-only chronological record of ingests/queries/lints
├── outputs/    — generated reports, briefings, answers
│                 ephemeral; promoted to wiki/ via /wiki-promote when valuable
└── CLAUDE.md   — schema file (focus areas, conventions, glossary)
```

## Where Knowledge Lives

| Knowledge type | Location |
|---|---|
| Cross-project concepts | `~/docs_gh/llm/knowledge/<domain>/` (central hub) |
| Project-specific | `<project>/wiki/` (per-project) |
| Confidential / PHI | Per-project with `.gitignore` + PHI scan |

The central hub at `~/docs_gh/llm/knowledge/` is **local-only git** —
never pushed to GitHub. See `wiki-storage-policy` rule.

## The Four Gaps (Why This Skill Exists)

Karpathy / Spisak describe the basic pattern but miss:

1. **Provenance** — which raw file does each wiki claim come from?
   → Solved by `provenance-mandatory` rule (mandatory `## Sources`)
2. **Versioning** — git, but with raw/ vs wiki/ awareness
   → Solved by `raw-folder-readonly` rule + file_protection.sh hook
3. **Validation** — does the wiki article still match its source?
   → Solved by multi-tier health check (T1-T4) + `critic` agent
4. **Confidence tracking** — AI-inferred vs source-stated
   → Solved by `confidence-markers` rule

## Workflow

### 1. Initialise a domain

```bash
cd ~/docs_gh/llm/knowledge       # central hub
mkdir -p <domain>/{raw,wiki,outputs}
```

Copy the starter `CLAUDE.md` template (below) into `<domain>/CLAUDE.md` and
edit the focus areas.

### 2. Fill `raw/` (manual or scripted)

- Drop transcripts, articles, screenshots into `raw/`
- Don't organise, don't rename, don't clean up
- Use any source: copy-paste, `youtube-transcript-api`, `agent-browser`, etc.
- Files in `raw/` are append-only — never edit existing files

### 3. Compile the wiki

Invoke the `wiki-curator` agent:

> Read everything in `raw/`. Compile a wiki in `wiki/` following the
> conventions in `CLAUDE.md`. Create `INDEX.md` first, then one `.md` file
> per major topic. Cross-link with `[[topic]]` syntax. Every claim must
> cite its raw source. Tag AI-inferred claims with `> ⚠ AI-inferred:`.

The curator will:
- Read `<domain>/CLAUDE.md` schema
- Read all files in `raw/`
- Produce `wiki/` files with mandatory `## Sources` sections
- Update `wiki/INDEX.md`
- Never modify files in `raw/`

### 4. Validate

Three layers:

- **T1 (automatic)**: `wiki_health_onwrite.sh` hook fires after every Edit/Write
- **T2 (pre-commit)**: full provenance + line-range validation
- **T3 (manual)**: `/wiki-health` for full 7-check report
- **T4 (weekly cron)**: optional launchd job, only if user enables

After a batch of compilation, run `/wiki-health` to get a full report.

### 5. Adversarial review

Invoke the `critic` agent with wiki validation mode:

> Review the wiki at <path>/wiki/ against the raw sources at <path>/raw/.
> Verify every cited line range actually contains the claimed content.
> Flag any fabricated quotes or missing confidence markers.

### 6. Ask questions, save answers to outputs/

Once the wiki has 10+ articles, query it:

> Based on everything in `wiki/`, compare how source A and source B treat
> [topic]. Where do they disagree? Save the answer to `outputs/`.

Outputs are regenerable — never edit them by hand.

## Mandatory Conventions

| Convention | Why |
|---|---|
| `raw/` is append-only | Prevents AI output → AI input feedback loop |
| Every `wiki/*.md` has YAML frontmatter (see below) | Queryable metadata, lifecycle, freshness |
| Every `wiki/*.md` ends with `## Sources` | Auditability |
| `[[topic]]` syntax for cross-wiki links | Tool-agnostic, Obsidian-compatible |
| AI-inferred claims tagged `> ⚠ AI-inferred:` | Distinguishes facts from synthesis |
| `wiki/INDEX.md` lists all topics | Discoverability |
| `wiki/LOG.md` records every ingest, query, lint | Auditable timeline of wiki evolution |
| `outputs/` is regenerable | Single source of truth = wiki |
| Query answers promoted via `/wiki-promote` | Valuable explorations compound into the wiki |

## YAML Frontmatter Schema

Every `wiki/*.md` file MUST begin with YAML frontmatter. Required fields:

```yaml
---
title: Curve Carry
canonical_question: "How does commodity curve carry generate returns?"
status: active                           # active | stale | superseded
fresh_until: 2026-07-09                  # YYYY-MM-DD; health check flags overdue
consensus_level: strong                  # unanimous | strong | split | divergent | direct
sources:
  - flirting-with-models-faheem-osman-commodity-qis.md
  - flirting-with-models-gerald-rushton-commodity-strategies.md
compiled_by: claude-opus-4-6
compiled_on: 2026-04-09
---
```

Optional fields:

```yaml
tags: [commodity, futures, qis, macquarie]  # categorisation for search
supersedes: old-curve-carry.md               # version chain
parent: strategy-comparison.md               # hierarchical structure
```

### Field semantics

| Field | Required | Purpose |
|---|---|---|
| `title` | MUST | Human-readable title (may differ from filename) |
| `canonical_question` | MUST | The definitive question this page answers; prevents duplicate pages for same concept |
| `status` | MUST | Lifecycle: `active` (current), `stale` (past `fresh_until`), `superseded` (replaced) |
| `fresh_until` | MUST | ISO date; health check transitions page to `stale` when this passes |
| `consensus_level` | MUST | `unanimous` / `strong` / `split` / `divergent` across cited sources, or `direct` for single-source pages and summaries |
| `sources` | MUST | List of `raw/` filenames cited in the `## Sources` section |
| `compiled_by` | SHOULD | Model ID that compiled this page (lets you identify pages produced by older models) |
| `compiled_on` | SHOULD | ISO date of last compilation |
| `tags` | MAY | Search/filter categorisation |
| `supersedes` | MAY | Filename of the previous version this replaces |
| `parent` | MAY | Filename of the hierarchical parent topic |

### Consensus levels

Consensus describes agreement **across cited sources**, not across AI models:

| Level | When to use |
|---|---|
| `unanimous` | All cited sources state the same thing with no disagreement |
| `strong` | Sources agree on core claims; differ on emphasis or edge cases |
| `split` | Sources agree on some claims, diverge substantively on others — use `> ❓ Conflicting:` markers in body |
| `divergent` | Sources reach fundamentally different conclusions — this is valuable, not a failure |
| `direct` | Single source, summary page, or comparison file — no cross-source consensus to measure |

## LOG.md Convention

Each domain's `wiki/LOG.md` is **append-only chronological**. Every ingest, query,
lint pass, and output promotion gets one entry. Parse-friendly format:

```markdown
# Wiki Log — <domain>

## [2026-04-09] ingest | Flirting with Models S7E29: Faheem Osman
- Source: raw/flirting-with-models-faheem-osman-commodity-qis.md
- Pages touched: curve-carry.md (new), congestion.md (new), commodity-vol-carry.md (new), INDEX.md (update), summary-faheem-osman.md (new)
- AI-inferred markers added: 7
- Consensus level: strong on curve carry, split on "no negative years" claim

## [2026-04-09] lint | /wiki-health
- Errors: 0, Warnings: 0
- Stale pages: 0, Orphan raw: 0, Dead links: 0

## [2026-04-09] query | "How do curve carry and congestion differ on correlation?"
- Output: outputs/carry-vs-congestion-correlation-2026-04-09.md
- Promoted: no (kept in outputs/)
```

The consistent `## [YYYY-MM-DD] <op> | <title>` prefix makes the log
greppable: `grep "^## \[" LOG.md | tail -10` gives the last 10 entries.

Operations:
- `ingest` — new raw/ file processed into wiki/
- `query` — user asked a question against the wiki
- `lint` — /wiki-health run
- `promote` — outputs/ file promoted to wiki/ via /wiki-promote
- `supersede` — wiki file replaced by a new version

## Search Tools

At small scale (<100 wiki pages), `INDEX.md` + `grep` is enough:

```bash
# Topic lookup
grep -l "curve carry" ~/docs_gh/llm/knowledge/qis-strategies/wiki/*.md

# Full-text search with context
grep -rn "backwardation" ~/docs_gh/llm/knowledge/qis-strategies/wiki/

# Find all pages with a specific tag in frontmatter
grep -l "tags:.*commodity" ~/docs_gh/llm/knowledge/qis-strategies/wiki/*.md

# Find stale pages
grep -l "^status: stale" ~/docs_gh/llm/knowledge/qis-strategies/wiki/*.md
```

At larger scale, consider `qmd` — a local markdown search engine with
hybrid BM25+vector search and LLM re-ranking:

- Project: `github.com/tobi/qmd`
- CLI + MCP server
- All on-device, no cloud

Installation is optional; the `knowledge-base-wiki` pattern works without
it. When installed, `qmd search "topic"` beats grep on ranked relevance.

## Starter `CLAUDE.md` Template

```markdown
# <Domain> Knowledge Base

## What This Is
A knowledge base focused on [TOPIC].

## Focus Areas
1. [area 1]
2. [area 2]
3. [area 3]

## Conventions
- raw/ is append-only — never modify existing files
- Every wiki file has `## Sources` listing raw files with line ranges
- Cross-wiki links use [[topic-name]] syntax
- AI-inferred claims tagged with `> ⚠ AI-inferred:`
- INDEX.md lists every topic with one-line description

## Glossary
- [Term]: [definition]

## Citation Style
- Inline: `([file.md:LINE](raw/file.md#LLINE))`
- Block quote: `> "quoted text" — [file.md:LINE](raw/file.md)`
- Footnote: `[^1]: raw/file.md, lines N-M`
```

## What This Skill Replaces / Avoids

| Spisak/Karpathy approach | Our approach |
|---|---|
| "Let the AI organize raw/" | Curator agent with mandatory provenance |
| Monthly health check | Multi-tier T1-T4 (T1 on every write) |
| No source tracking | Mandatory `## Sources` section |
| No AI-vs-source distinction | `confidence-markers` rule |
| `agent-browser` CLI (unverified claims) | Use any scraper per-project |
| Obsidian + plugins | Plain markdown + git |

## Related Rules

- `raw-folder-readonly` — append-only enforcement
- `provenance-mandatory` — citation requirements
- `confidence-markers` — AI-inferred tagging
- `wiki-storage-policy` — central hub vs per-project
- `safe-deletion` — confirmation for raw/ deletions

## Related Agents

- `wiki-curator` — compiles `raw/` → `wiki/`
- `critic` (wiki validation mode) — adversarial review

## Related Commands

- `/wiki-health` — T3 full health check
