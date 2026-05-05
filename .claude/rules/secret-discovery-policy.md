---
name: secret-discovery-policy
description: An agent must never silently use a discovered credential — stop, name the file and intended operation, confirm with user or SECRETS.md before proceeding
type: rule
---

# Rule: Secret Discovery Policy

## Source

PocketOS / Cursor / Railway incident 2026-04-25
([thread](https://x.com/lifeof_jer/status/2048103471019434248)):
an agent grepped a token from an unrelated file, used it without asking, and
triggered `volumeDelete` — a GraphQL mutation whose scope (full account, including
backups) was wider than the user knew. The token was valid; the intent was not.

Grounded in real-world surface area: a 2026-05-05 audit of `~/docs_gh/*` found
19 projects with `.Renviron` or `.env` files, 30+ distinct env-var names, and top
usage hotspots in `blogs` (143 call sites), `proj` (131), `datageeek.com` (111).
Any grep or file-search in that tree can surface live credentials.

## When This Applies

Any time the agent is about to use a token, API key, password, or credential,
regardless of how it was found — env var, `.Renviron`, grep result, hardcoded
string, or any other discovery path.

## CRITICAL: Discovery Is Not Authorisation

Finding a credential in a file does not mean the agent is authorised to use it
for the current operation. The gap between "scope intended" and "scope actual at
provider" is where incidents happen. Before using any discovered credential, the
agent must:

(a) Name the file path the credential came from.
(b) Name the operation it intends to perform.
(c) Confirm the credential is listed in the project's `SECRETS.md` for that
    operation, OR stop and ask the user.

## Decision Table

| How the credential was found | Required action |
|---|---|
| Env var explicitly passed at session start (e.g. `export GH_TOKEN=...`) | Use; mention which env var and the intended operation |
| `.Renviron` value retrieved via `Sys.getenv()` in a task the user assigned | Use; mention the var name and operation |
| Token in a file the agent is actively editing as the task's intent | Use; this is in scope |
| Token found via grep/search of an unrelated file | **Stop. Name the file path and the operation. Ask the user before using.** |
| Token whose scope in `SECRETS.md` does not cover the intended operation | **Stop. Report the scope gap. Do not proceed without explicit user confirmation.** |
| Token not listed in `SECRETS.md` at all | **Stop. Ask the user to verify scope before use.** |

## Forbidden Patterns

| Pattern | Why wrong |
|---|---|
| Agent greps codebase for `API_KEY`, finds a token in an unrelated file, uses it silently | The source-incident pattern — discovery ≠ authorisation |
| `Sys.getenv("GH_TOKEN")` used for a `DELETE` operation without mentioning it | Scope may exceed intent; user can't review what they can't see |
| Assuming a `*_READ_KEY` has read-only scope without checking the provider | Token names are not enforced by providers |
| Using a token because "it was there in `.Renviron`" | Presence ≠ permission for this operation |
| Proceeding after a scope gap is identified without explicit user confirmation | Unilateral escalation of privilege |

## SECRETS.md Template

The canonical per-project credential inventory template lives at:
`~/docs_gh/llm/.claude/templates/SECRETS.md`

Copy it into a project, gitignore it, and populate the "Scope (actual)" column
from the provider's token management UI (not from the variable name).

## Related

- `permission-mode-discipline` — binds `--permission-mode` to workspace type;
  this rule adds credential-specific stop conditions independent of permission mode
- `destructive-api-calls` — hook-level blocking of destructive verbs; this rule
  adds the pre-use confirmation layer that fires before any API call is constructed
- `credential-management` — storage and rotation hygiene (Sys.getenv patterns,
  .Renviron, CI secrets); this rule adds the agent-behaviour layer on top
