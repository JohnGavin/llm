---
name: mcp-destructive-scope
description: Classify every MCP server's tools as read/write/destructive before wiring; default unclassified tools to destructive; disable or require per-call approval for destructive tools
type: rule
---

# Rule: MCP Tool Classification Before Wiring

## Source

PocketOS / Cursor / Railway incident 2026-04-25
([thread](https://x.com/lifeof_jer/status/2048103471019434248)):
a flagship-model agent deleted a production volume via a single GraphQL mutation
wired through an MCP server with no per-tool approval. The server's token had
blanket scope — read and delete shared the same credential.

This user's current MCP posture: **r-btw** is the only actively wired MCP
(covered in detail by `btw-timeouts`). Gmail, Google Calendar, and Google Drive
appear as deferred-tool registrations but expose only `*_authenticate` and
`*_complete_authentication` endpoints — the attack surface is zero until
authentication completes.

## When This Applies

Every MCP server you authenticate, install, or wire into Claude Code's
`~/.claude/settings.json` or any project `.claude/settings.json`.

## CRITICAL: Classify Before Wiring; Default to Destructive

Every MCP server's tool list MUST be classified into three tiers before the
server goes live:

| Tier | Meaning | Approval required? |
|---|---|---|
| `read` | Queries only; no side effects; repeatable | No — auto-approve |
| `write` | Creates or modifies state; reversible with effort | Per-session confirm |
| `destructive` | Deletes, deprovisions, overwrites, or hangs the session indefinitely | Per-call approval OR disabled |

**Default when not yet inventoried: `destructive`.** Assume the worst until
each tool is explicitly classified and documented in this rule's table below.

Destructive tools MUST either be disabled in `settings.json`
(`"disabled": true` in the tool config) or trigger a per-call approval prompt.
They MUST NOT run silently in any permission mode, including `bypassPermissions`.

## Current MCP Classification Table

| MCP server | Approximate tool count | Read | Write | Destructive | Status |
|---|---|---|---|---|---|
| r-btw | ~31 (varies with btw version; 22 confirmed in current session) | `docs_*` (5), `files_list/read/search` (3), `sessioninfo_*` (3), `env_describe_*` (2), `list_r_sessions`, `select_r_session` | `files_write` | `run_r`, `pkg_test`, `pkg_check`, `pkg_coverage`, `pkg_document`, `pkg_load_all` — destructive in the sense of hanging the session indefinitely with no cancellation path | Active; destructive tools covered by `btw-timeouts` (use Bash+timeout instead) |
| Gmail | auth stubs only | — | — | — | Inactive — `authenticate` + `complete_authentication` only; no email access until auth completes |
| Google Calendar | auth stubs only | — | — | — | Inactive — same; zero attack surface |
| Google Drive | auth stubs only | — | — | — | Inactive — same; zero attack surface |

Note: the btw tool count is approximate. The subset active in this session is
`btw::btw_tools(c('docs', 'pkg', 'files', 'run', 'env', 'session'))`.

## Pre-Install Checklist (Required for Every New MCP)

Before adding any MCP server to `settings.json`:

- [ ] **Inventory the full tool list** — enumerate every tool the server exposes
      (check its README, schema, or source). Do not assume from the name alone.
- [ ] **Classify each tool** as `read`, `write`, or `destructive`; when ambiguous
      default to `destructive` until proven otherwise.
- [ ] **Document the classification** in this rule's table above; commit the
      update *before* the server goes live.
- [ ] **Decide the approval posture** — disable destructive tools in
      `settings.json`, or configure per-call approval; never silently allow.
- [ ] **Verify the auth-token scope** at the provider — confirm that the token
      granted to Claude Code cannot exceed the read/write scope you need.
      A blanket token that includes delete permissions is disqualifying unless
      the destructive tools are disabled.
- [ ] **Record the token and scope** in `SECRETS.md` per the template in #102.
- [ ] **Test in a scratch workspace** (`bypassPermissions` + `/tmp/`) before
      enabling in any main checkout.

## Default Posture

Disable any MCP not actively in use. The current active set MUST be: **r-btw
only**. Gmail, Calendar, and Drive may remain as deferred-tool registrations
(they are inert stubs) — their presence is acceptable because no auth
credential has been granted to Claude Code.

If a previously active MCP is no longer needed, remove it from `settings.json`
rather than leaving it enabled. An idle MCP with a valid token is a standing
attack surface.

## Forbidden Patterns

| Pattern | Why wrong |
|---|---|
| Wiring an MCP without classifying its tools | Unknown destructive surface; violates this rule |
| Trusting the MCP's own label ("safe", "read-only") without verifying scope at the provider | Labels are advisory; token grants are authoritative |
| Using a blanket auth token when a scoped token is available | Unnecessary blast radius |
| Wiring a destructive MCP into a `bypassPermissions` workspace | Per-call approval never fires in bypass mode |
| Leaving a previously active MCP enabled after its task is complete | Idle token = standing attack surface |
| Skipping the pre-install checklist under time pressure | No classification = assume destructive |

## Related

- `btw-timeouts` — r-btw–specific rule; bans direct MCP calls for R execution;
  defines the safe read-only subset for r-btw
- `destructive-api-calls` — hook-level blocking of curl/gh/aws/fly destructive verbs;
  complements this rule (MCP calls bypass the Bash hook — this rule is the MCP axis)
- `secret-discovery-policy` — token storage and rotation
- `permission-mode-discipline` — binds `--permission-mode` to workspace type;
  this rule adds MCP-level classification on top of mode-level permission
- `mcp-servers` skill — MCP server configuration and management (do not edit that
  file to add the checklist; it is a separate concern)
