---
description: Any control deciding what leaves the machine must default to deny (allowlist or a marker on the item itself) — an exclusion list is fail-open and grows a disclosure gap silently
paths:
  - "**/privacy_exclusion*.R"
  - "**/*dashboard_data*.R"
  - "**/*export*dashboard*.R"
  - "**/.roborev.toml"
  - "**/*publish*.R"
  - "**/*publish*.sh"
  - "**/*artifact*.sh"
  - "**/capability_registry_regen*"
---

# Rule: Default-Deny for Publication Controls

## Press release (per `press-release-first`)

When writing or reviewing any control that decides what data, rows, or
projects get published/exported/exposed beyond the current machine — a
dashboard's project allowlist/denylist, a data-export filter, roborev's
`exclude_patterns` — this rule requires the control's default direction to be
**deny**, not permit. A control expressed as "here is what to exclude" is
fail-open: anything not yet named is published, and nothing announces the
omission.

## Chesterton check

[`public-private-repo-boundary`](public-private-repo-boundary.md) decides
*which repo* a file belongs in. This rule is narrower: which *rows* a
publication filter may show inside an already-public project.

## CRITICAL: A Filter That Works Correctly Is Not the Same as a Filter With the Right Default

`llmtelemetry` published ~584 rows of `premortem` (a private project)
session data to a **public** repo from 26 May onward — session IDs,
timestamps, durations, token and cost aggregates. `R/privacy_exclusion.R`
existed the whole time and worked correctly: every project named in it had
zero occurrences in the published output. `premortem` was simply never added.

> The filter was not broken. The default was.

## Required Pattern

A publication control MUST be expressed as ONE of:

1. **An allowlist** — only named items are published; everything else is
   withheld by default.
2. **A marker carried by the item itself** — the decision lives next to the
   data (e.g. a `PRIVATE` file in a project directory, a frontmatter flag on
   a dataset), so it survives the project being renamed, moved, or forked. A
   central list does not.

An **exclusion list is acceptable only** where the failure mode of a missed
entry is noise, never disclosure, and the file must say so in a comment at
the point of definition (e.g. `# ALLOWED denylist shape: failure mode is
dashboard noise, not disclosure. See default-deny-for-publication.md.`).

## Decision Table

| Surface | Current shape (as of 2026-08-22 audit) | Failure mode of a missed entry | Correct shape |
|---|---|---|---|
| `llmtelemetry` dashboard projects | denylist (`excluded_dashboard_projects()`) | disclosure (llmtelemetry#347/#348) | allowlist |
| `knowledge/` push protection | `PRIVATE` marker + pre-push hook | — | already correct (marker form) |
| Artifact publication | human judgement per publish; checker `check_artifact_sources.sh` not yet wired | disclosure | source allowlist file, see "Artifact data sources" |
| roborev `exclude_patterns` | denylist per repo | noise (spurious findings), not disclosure | denylist acceptable, per this rule's exception — see `roborev-exclude-patterns` |

## Artifact data sources

A claude.ai Artifact may only embed or attach data whose SOURCE is listed in
`.claude/state/artifact_publish_allowlist.txt` (TAB-separated `source`,
`review-date`, `reason`; empty allows nothing). Attached files are readable by
anyone who can open the Artifact. Session/usage logs are NEVER allowlisted:
the unified DuckDB, prompt previews or text, roborev review text. Run
`.claude/scripts/check_artifact_sources.sh <path>...` first (0 only if every
path is allowlisted and none hits a hard deny pattern, which wins over the
allowlist; 1 denied; 2 usage; 3 indeterminate). Wiring it as a PreToolUse
guard is a follow-up; the Artifact hook matcher is a known gap
([llm#996](https://github.com/JohnGavin/llm/issues/996)).

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---|---|---|
| A denylist of "sensitive projects" with no comment justifying the shape | Silently fail-open; the next new project is published by default | Convert to allowlist, or add the noise-not-disclosure comment |
| Treating "the filter had zero false negatives in testing" as proof the shape is safe | Tests confirm the filter *works*, not that its *default* is safe when a new item is never added | Ask: what happens to a thing nobody classified? If it ships, invert the list |
| A central exclusion list for something that could instead carry a marker | The list drifts out of sync with the thing it's excluding; a marker travels with its data | Prefer the marker form (see `knowledge/`'s `PRIVATE` file) |

## Related

- [`public-private-repo-boundary`](public-private-repo-boundary.md) — which
  *repo* something belongs in; this rule governs the shape of in-repo
  publication filters once that decision is already correct
- [`roborev-exclude-patterns`](roborev-exclude-patterns.md) — a denylist this
  rule's exception clause explicitly covers (noise, not disclosure)
- [`checks-must-distinguish-unknown`](checks-must-distinguish-unknown.md) —
  sibling failure mode from the same week: a check that cannot fail, vs. here
  a control whose default is wrong even when it works perfectly
- `.claude/memory/feedback_default-permit-is-fail-open.md` — memory capture
  of the same incident
- [#1010](https://github.com/JohnGavin/llm/issues/1010) — origin issue
- llmtelemetry#347, #348, #350 — the concrete incident and fixes
