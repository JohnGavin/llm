# Companion: Wiki Conventions — Migration History + Enforcement-Scope Detail

Historical/rationale detail split out of the always-loaded
[`wiki-conventions`](../wiki-conventions.md) rule to keep it lean. The
normative content (the 7 Parts, required frontmatter fields, tables,
Enforcement tiers) stays in the rule; this file is the migration narrative and
the finer-grained enforcement-scope notes, loaded on demand.

## `consensus_level` Enum Migration (llm#759)

As of llm#759 Phase 2, the schema's `consensus_level` enum is
`unanimous | strong | split | divergent | direct` — the vocabulary documented
in the parent rule's Part 5. The interim Phase-1 `high | direct` vocabulary is
retired; existing pages using `high` are migrated to `strong` separately (not
part of this rule — tracked as a one-time data-migration task under llm#759).

## Exempt-Pages Enforcement Scope

`wiki_health_check.sh` (llm#759 Phase 2) skips the frontmatter, provenance,
staleness, and lifecycle checks for exempt pages in BOTH `--single` mode and
full mode, and excludes them from the frontmatter/sources denominators in the
full-mode report (the `exempt_pages` count). The dead-`[[wiki-link]]` check
still runs regardless of exemption status — exemption is not a license for
broken links.

Use the `<!-- wiki:exempt -->` marker sparingly: `INDEX.md` and `LOG.md` are
already exempt by filename and do not need the marker.

## Sections Moved from the Rule Body (2026-07-29 line-limit pass, llm#749)

### Rule Consolidation History

Consolidated from: `wiki-frontmatter`, `wiki-storage-policy`, `wiki-staleness-check`, `raw-folder-readonly`, `provenance-mandatory`, `confidence-markers`, `glossary-management`.

### Hub Structure

```
~/docs_gh/llm/knowledge/
├── PRIVATE               ← marker blocks push
├── <domain>/
│   ├── raw/              ← APPEND-ONLY
│   ├── wiki/             ← AI-maintained
│   └── outputs/          ← ephemeral
```

### Wiki Frontmatter — worked example

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

### Provenance — worked examples

Every wiki file MUST cite sources:

```markdown
The strategy works because hedgers are price-insensitive
([transcript.md:450](raw/transcript.md#L450)).
```

Every `wiki/*.md` ends with:

```markdown
## Sources

- [file.md](../raw/file.md) — lines 715-795 (topic)
```

### raw/ Append-Only — rationale

Modifying `raw/` corrupts the provenance chain and creates an "AI output →
input" feedback loop.

### Cross-Wiki Links — worked example

Use double-bracket syntax:

```markdown
See also [[congestion]] and [[commodity-vol-carry]].
```
