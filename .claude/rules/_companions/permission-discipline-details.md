---
paths:
  - ".claude/rules/permission-discipline.md"
---

# Companion: Permission Discipline — Known Gap Rationale (mcp__* Content Guard)

Dated rationale detail split out of the always-loaded
[`permission-discipline`](../permission-discipline.md) rule to keep it
under the repo's line-count budget. The normative content (Part 1-4
CRITICAL statements, decision tables, Forbidden tables, Related) stays in
the rule; this file is the full "Known Gap" investigation rationale
(llm#996), loaded on demand.

## Known Gap: No `PreToolUse` Content Guard on `mcp__*` (llm#996, dated 2026-08-29) — full rationale

`secret-leak-prevention.md` documents content-inspecting `PreToolUse` guards
on `Bash` (`secret_leak_guard.sh`), `gh --body`/`--body-file` (the same
hook's Rules 1/5), and `Artifact` (`artifact_secret_guard.sh`, confirmed
blocking in production 2026-08-21). `.claude/settings.json` currently has
**zero** `PreToolUse` hooks matching `mcp__*` — no guard and no telemetry
shape-probe. This is a **known, deliberate, tracked gap**, not an oversight:
recorded here per llm#996's own framing ("either cover them, or record why
not").

Why no guard was added now, rather than deferred silently again:

1. **The matcher itself is unverified.** `Artifact` and `WebFetch` were only
   confirmed as valid `PreToolUse` matchers by an empirical probe
   (`tool_input_probe.sh`, see secret-leak-prevention.md's "ANSWERED
   2026-08-14" section) — the docs list of matchers omits both, and omitted
   them wrongly. `mcp__*` has never been probed the same way; whether it
   fires at all, and what shape `tool_input` carries for an MCP tool call,
   are both open questions, not assumptions safe to build a blocking guard on.
2. **llm#996's own text is explicit that an untested safety hook is worse
   than a documented gap** — the prior PR (#991) deliberately did not attempt
   a guard here for the same reason.
3. Of the current MCP table above, only `mcp__r-btw__btw_tool_files_write`
   is classified `write`-tier — everything else is `read` (auto-approved,
   no guard needed by this rule's own Part 2 policy) or an inactive auth
   stub. A single `write`-tier tool is a narrow enough surface that a
   probe-then-guard sequence (mirroring the `Artifact`/`WebFetch` precedent:
   ship a `tool_input_probe.sh`-style shape observer first, confirm the
   matcher fires and what `tool_input` actually carries, only then build a
   content guard against the confirmed shape) is the right next step — but
   that is a multi-step, verifiable-in-production sequence, not something to
   improvise inside an unrelated dispatch.

**Concrete trigger condition for building the guard:** either (a) a second
`write`- or `destructive`-tier MCP tool is added to the table above, raising
the exposure surface beyond one tool, or (b) a `tool_input_probe.sh`-style
shape probe on the `mcp__*` matcher lands and confirms the matcher fires and
what `tool_input` looks like for at least `btw_tool_files_write` — whichever
comes first. Until then this table's `write` classification is the only
control on that tool (per-session approval, per Part 2 above); there is no
content-level inspection.


## Moved from the `permission-discipline` rule body (2026-10-03, always-loaded baseline trim)

Verbatim text removed from the rule body to cut the always-loaded instruction baseline. The normative requirement is restated in the rule; this is the supporting detail.

### Safety-critical tier: scoping history

This rule was scoped to `.claude/settings*.json`, `.claude/hooks/**`,
`**/.mcp.json` — it did not load when running arbitrary Bash, which is when
permission decisions (Part 1: `bypassPermissions` binding) are actually
made. Per [llm#943](https://github.com/JohnGavin/llm/issues/943), this rule
is now in the **safety-critical tier** declared in AGENTS.md's
"Safety-critical rules" line and carries no `paths:` frontmatter — it loads
into every session and every subagent, matching the mandatory tier's
contract.

Consolidated from: `permission-mode-discipline`, `mcp-destructive-scope`, `prod-staging-context-guard`, `secret-discovery-policy`.

Source: PocketOS / Cursor / Railway incident 2026-04-25.

### Pre-Install Checklist and Known Gap (llm#996)

### Pre-Install Checklist

- [ ] Inventory full tool list
- [ ] Classify each as read/write/destructive
- [ ] Document in this rule's table
- [ ] Verify auth-token scope at provider
- [ ] Test in scratch workspace first

### Known Gap: No `PreToolUse` Content Guard on `mcp__*` (llm#996, dated 2026-08-29)

`.claude/settings.json` currently has **zero** `PreToolUse` hooks matching `mcp__*` — no content guard and no telemetry shape-probe, unlike `Bash`/`gh --body`/`Artifact`. This is a **known, deliberate, tracked gap**, not an oversight: the `mcp__*` matcher itself is unverified (never probed the way `Artifact`/`WebFetch` were), and only one tool (`mcp__r-btw__btw_tool_files_write`) is even `write`-tier — a probe-then-guard sequence is the right next step, not something to improvise inside an unrelated dispatch. Full rationale and the concrete trigger condition for building the guard: companion doc.

### Part 3: Environment Declaration (convention snippet, values, project audit)

## Part 3: Environment Declaration

### The Convention

Every project's `.claude/CLAUDE.md` SHOULD declare:

```markdown
| Field | Value |
|-------|-------|
| Environment | dev |
```

### Valid Values

| Value | Meaning |
|---|---|
| `research` | Exploratory; no live users (default if unspecified) |
| `dev` | Tooling, config, packages |
| `prod` | Live service, published website |
| `mixed` | Both prod and non-prod surfaces |

### Project Audit

| Project | Environment |
|---|---|
| `llm` | `dev` |
| `JohnGavin.github.io` | `prod` |
| `llmtelemetry` | `prod` |
| `randomwalk`, `irishbuoys`, `mycare`, `footbet` | `research` |


## Moved from the `permission-discipline` rule body (2026-10-03, always-loaded baseline trim)

Verbatim text removed from the rule body to cut the always-loaded instruction baseline. The normative requirement is restated in the rule; this is the supporting detail.

### markitdown-mcp row (full)

| markitdown-mcp | `convert_to_markdown` (file path → markdown text; no side effects on source) | — (if a write-to-disk variant is exposed, classify as **write** and require per-session approval) | No auth token; local execution only. No destructive tools identified in upstream README. |
