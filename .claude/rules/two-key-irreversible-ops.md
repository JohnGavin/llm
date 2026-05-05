---
name: two-key-irreversible-ops
description: Irreversible ops require the user to type a confirmation phrase containing the target name verbatim — same-turn agent echo of the target name is forbidden
type: rule
---

# Rule: Two-Key Principle for Irreversible Operations

## Source

PocketOS / Cursor / Railway incident 2026-04-25
([thread](https://x.com/lifeof_jer/status/2048103471019434248)):
an agent deleted a production volume (and its backups) in 9 seconds after a single
GraphQL mutation. A system-prompt rule said "never run destructive ops unless
explicitly requested". The rule was advisory; the agent complied with it by treating
its own confidence as confirmation. Two-key closes that gap: the user must produce
the target name from memory, not read it back from the agent's prompt.

## When This Applies

- Any irreversible op that `destructive-api-calls` (#101) blocks at the hook level
- Any irreversible op the agent proposes before requesting confirmation:
  drop table, delete volume, force-push to a shared branch, `rm -rf` >100MB,
  schema destructive change, production deploy from an agent session

## CRITICAL: The User Supplies the Target Name

The confirmation phrase must contain the target name verbatim. The agent MUST NOT
print the target name in the same turn as the confirmation prompt. If the agent
writes "type `APPROVE-DELETE-prod-db`", a copy-paste or a distracted "ok" defeats
the intent. The user typing `prod-db` from short-term memory proves they know what
they are approving.

## Op Classes

| Class | Examples | Confirmation form |
|---|---|---|
| **Class A** — catastrophic, shared-state | `DROP TABLE users`; delete prod volume; force-push to `main`; `gh repo delete`; mass account-level delete | Target name typed by the user **plus** an out-of-band acknowledgement (SMS to a second device, YubiKey touch, email confirm) |
| **Class B** — destructive, recoverable | Local `rm -rf` >100MB; `git reset --hard`; truncate large CSV; `git push --force` to a personal branch with collaborators | Target name typed by the user in a confirmation phrase (e.g. `DELETE proj-data-archive`) |
| **Class C** — destructive, fully reproducible | Clear `_targets/` cache; remove `_freeze/`; delete a throw-away `/tmp` directory | Standard prompt ("Are you sure?"); no two-key required — these are fully regenerable |

## Why Same-Turn Echo Is Forbidden

The agent already has the target name in its context window. If it prints
"Please type `prod-db` to confirm", the user's copy-paste or "ok" provides zero
additional signal — they did not recall the target, they transcribed it.
Same-turn echo collapses the confirmation into a single principal,
exactly like using one key for a two-key lock.

Correct form: the agent describes the operation in general terms ("I am about to
delete the production database volume"), then asks the user to name the target from
memory before it proceeds.

## OOB Requirement

Out-of-band acknowledgement (Class A) is documented here but not currently
enforced by hook or script. This user is a solo developer on research projects
with no live production databases. OOB is a design requirement for any future
multi-user or production-grade deployment; it is not triggered today so the rule
does not impose friction on current workflows.

## What This Rule Does NOT Do (Yet)

Hook enforcement of the target-name requirement — specifically, verifying that
the confirmation phrase the user typed actually matches the operation target —
is not implemented. That requires modifying `destructive_api_guard.sh` to parse
the confirmation phrase and compare it to the proposed target. This is tracked
as a follow-up (see issue #103 closing comment).

## Forbidden Patterns

| Pattern | Why wrong |
|---|---|
| Agent prints target name in the confirmation prompt, then accepts the user's echo | Same-turn echo — single principal |
| Agent accepts "yes", "y", or "ok" for Class A or B operations | No target-name recall; a distracted or automated ack succeeds |
| Agent retries a slightly reworded prompt after user refusal | Persistence pressure collapses to eventual consent |
| Agent proceeds because the system prompt says "user already approved this class of op" | Advisory approval at session start is not per-operation two-key |

## Related

- `destructive-api-calls` — hook-level blocking (#101); this rule adds
  the human-confirmation layer that fires when a blocked op is genuinely needed
- `permission-mode-discipline` — binds `--permission-mode` to workspace type;
  this rule adds confirmation-phrase discipline independent of permission mode
- `safe-deletion` — `rm` discipline; this rule classifies deletions by
  reversibility and sets the confirmation form for each class
- `systematic-debugging` — investigate before acting; this rule applies that
  principle to the confirmation step (understand what you're deleting before typing its name)
