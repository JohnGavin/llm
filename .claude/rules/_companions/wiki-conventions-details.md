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
