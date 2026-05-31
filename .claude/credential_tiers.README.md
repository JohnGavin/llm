# credential_tiers.toml — Format and Setup Guide

## Purpose

`credential_tiers.toml` defines which environment variable names (from
`~/.Renviron`) require explicit human confirmation before an autonomous Claude
Code agent may use them, and which may be used without a per-call prompt.

The `permission_request.sh` hook reads this file at every tool call that
involves a credential name. The live file is gitignored; the template ships
with representative examples.

## Two Tiers

| Tier | Meaning | Agent behaviour |
|------|---------|-----------------|
| `[auto]` | Read-only keys, internal paths | Used without human prompt |
| `[ask]` | Write-capable, billing, or high-value keys | Requires explicit confirmation |
| *(unlisted)* | Anything not categorised | Treated as `[ask]` (zero-trust default) |

**When in doubt, leave it in `[ask]`.** You can always demote a key to `[auto]`
once you have verified it is read-only and low blast-radius.

## Setup

```bash
# 1. Copy the template
cp .claude/credential_tiers.toml.template .claude/credential_tiers.toml

# 2. List the key names in your ~/.Renviron (never the values)
grep -E '^[A-Z_]+\s*=' ~/.Renviron | cut -d= -f1

# 3. Edit .claude/credential_tiers.toml:
#    - Move each key name into [auto] or [ask]
#    - Leave the template's example names as comments if helpful
```

## File Format

```toml
[auto]
keys = [
  "KEY_NAME_ONE",
  "KEY_NAME_TWO",
]

[ask]
keys = [
  "HIGH_RISK_KEY",
  "BILLING_API_KEY",
]
```

- Values are the environment variable NAMES (not values).
- Names must be quoted strings inside a TOML array.
- Comments with `#` are allowed anywhere.
- The file is parsed by the bash hook using simple `grep`/`awk` — full TOML
  parser is NOT used. Stick to the array-of-strings format shown above.

## How the Hook Uses This File

`permission_request.sh` searches for the credential name in the tool input:

1. If the name appears in `[auto].keys` → allow without prompt.
2. If the name appears in `[ask].keys` → require confirmation (exit 0 → human prompt).
3. If the name is not listed → treat as `[ask]` (zero-trust default).
4. If the file is missing or malformed → warn to stderr + treat all as `[ask]`.

The hook NEVER reads credential values — it only pattern-matches the variable
name as a string appearing in the command or tool input.

## Updating After Key Rotation

When you rotate a key (new value, same name), no change to this file is needed.

When you add a new key to `~/.Renviron`, add its name to the appropriate tier
in `.claude/credential_tiers.toml` before the next session.

## Self-Test

```bash
CLAUDE_HOOK_SELFTEST=1 bash .claude/hooks/permission_request.sh
```

The self-test includes four tier-enforcement cases:
- `ask`-tier key → blocked (requires human)
- `auto`-tier key → allowed
- unlisted key → blocked (zero-trust default)
- malformed toml → graceful skip + warning, not crash

## Related

- `.claude/credential_tiers.toml.template` — copy this to create your live file
- `.claude/hooks/permission_request.sh` — the hook that enforces tiers
- `.claude/rules/credential-management.md` — rule covering credential governance
- `permission-discipline` rule — broader MCP and workspace permission rules
- `llm#376` — origin issue (two-vault credential tier split)
