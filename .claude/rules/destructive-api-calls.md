---
description: Block destructive API calls (curl DELETE/PATCH/PUT/GraphQL mutations, gh api destructive verbs, aws delete, fly/railway volume destroy, DROP/TRUNCATE SQL) at hook level regardless of permission mode
---

# Rule: Destructive API Calls Are Blocked at the Hook Level

## Source

PocketOS / Cursor / Railway incident 2026-04-25
([thread](https://x.com/lifeof_jer/status/2048103471019434248)):
a flagship-model agent in unrestricted mode ran a single
`curl -X POST .../graphql -d 'mutation { volumeDelete(...) }'`
and deleted a production volume (and its backups) in 9 seconds.
The system-prompt rule "never run destructive ops" was advisory and was ignored.
The fix is enforcement at hook level — the advisory rule becomes a hard gate.

See also: `permission-mode-discipline` (companion rule that binds `--permission-mode`
to workspace type; this rule adds pattern-level blocking independent of permission mode).

## When This Applies

Every `Bash` tool call, in every project, in every permission mode, including
`bypassPermissions`. The hook fires before execution; exit 2 blocks the call.

## CRITICAL: Advisory Rules Are Not Enough

A rule that says "don't do X" is ignored by a sufficiently confident agent.
Hook-level enforcement exits non-zero *before* the command reaches the shell.
The process never starts. There is no "almost deleted" outcome.

## Blocked Patterns

The `PreToolUse:Bash` hook `~/.claude/hooks/destructive_api_guard.sh` blocks
commands matching any of the following patterns:

| Pattern | Catches |
|---|---|
| `curl .* -X (DELETE\|PATCH\|PUT)` | curl mutation verbs when `-X` precedes URL |
| `curl .* -X POST .* mutation[[:space:]]*\{` | GraphQL mutations via curl POST |
| `curl .*-d.* mutation[[:space:]]*\{` | GraphQL mutations via curl `-d` payload |
| `gh api .* -X (DELETE\|PATCH\|PUT)` | gh api destructive verbs (short form) |
| `gh api .* --method (DELETE\|PATCH\|PUT)` | gh api destructive verbs (long form) |
| `aws s3 (rb\|rm) ` | S3 bucket/object delete |
| `aws .* delete-` | aws delete-* subcommand family |
| `flyctl volumes? destroy` | fly.io volume destroy |
| `railway volumes? (delete\|destroy)` | railway volume delete/destroy |
| `psql.*-c.*(DROP\|TRUNCATE)[[:space:]]+(TABLE\|SCHEMA\|DATABASE)` | psql destructive SQL |
| `(duckdb\|sqlite3).*(DROP\|TRUNCATE)[[:space:]]+(TABLE\|SCHEMA)` | local DB destructive SQL |

## False-Positive Policy

The patterns are intentionally narrow. False positives (blocking a legitimate
safe operation) are worse than false negatives at this stage because:

1. False positives interrupt normal work and erode trust in the hook.
2. The underlying incident was a targeted single command — narrow patterns catch
   the class of incident without collateral damage.

Patterns are broadened only when a specific bypass vector is demonstrated.

## Escape Hatch (Intentional Destructive Operations)

When a destructive API call is genuinely required (e.g. deleting a test volume
in a CI teardown script):

1. Document the intent in a comment in the same shell script.
2. Run the command directly from a terminal (outside Claude Code), not via a
   Bash tool call.
3. For irreversible infrastructure deletes, require a second human to confirm
   (two-key handshake — see issue #103).

Never bypass the hook by base64-encoding the command or wrapping it in `eval`.

## Known Gaps (Tracked Follow-ups)

| Gap | Issue |
|---|---|
| Two-key handshake for genuinely required destructive ops | #103 |
| `gh api <url> -X DELETE` with flag at end of command (flag-after-URL form) | Future enhancement |
| `curl <url> -X DELETE` (flag after URL, not before) | Future enhancement |
| Terraform/Pulumi destroy | Not yet covered |
| `heroku ... destroy` | Not yet covered |

## Forbidden Patterns (for Claude agents)

| Pattern | Why wrong |
|---|---|
| `curl -X POST .../graphql -d '{"query":"mutation { volumeDelete(...) }"}'` | The exact incident vector |
| `curl -X DELETE https://api.example.com/resource` | Destructive REST call |
| `gh api repos/OWNER/REPO -X DELETE` | GitHub resource deletion |
| `aws s3 rm s3://bucket --recursive` | Mass S3 object deletion |
| `flyctl volumes destroy vol_abc` | fly.io volume loss |
| `railway volumes delete vol_xyz` | railway volume loss |
| `psql -c "DROP TABLE users"` | Irreversible table drop |
| `duckdb db.duckdb "DROP TABLE events"` | Local DB schema destruction |
| Routing around the hook via `eval $(...)` | Bypasses enforcement |

## Hook Location

`~/.claude/hooks/destructive_api_guard.sh` (symlinked from
`~/docs_gh/llm/.claude/hooks/destructive_api_guard.sh`)

## Related

- `permission-mode-discipline` — binds `--permission-mode` to workspace type;
  this rule adds pattern-level blocking that fires even in `bypassPermissions`
- `safe-deletion` — `rm` discipline for file-system deletes (subset of surface)
- `git-no-compound-cd` — git safety guard (separate enforcement axis)
- `credential-management` — prevents credentials from reaching API calls
