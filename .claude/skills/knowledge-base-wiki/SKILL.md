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
│                 AI maintains; mandatory ## Sources sections
├── outputs/    — generated reports, briefings, answers
│                 ephemeral; never the source of truth
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
| Every `wiki/*.md` ends with `## Sources` | Auditability |
| `[[topic]]` syntax for cross-wiki links | Tool-agnostic, Obsidian-compatible |
| AI-inferred claims tagged `> ⚠ AI-inferred:` | Distinguishes facts from synthesis |
| `wiki/INDEX.md` lists all topics | Discoverability |
| `outputs/` is regenerable | Single source of truth = wiki |

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
