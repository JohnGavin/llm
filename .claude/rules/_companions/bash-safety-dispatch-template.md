---
paths:
  - ".claude/agents/**"
  - ".claude/rules/auto-delegation.md"
---
# Bash Safety — Agent Dispatch Template

## Verbatim prefix for every Agent dispatch that involves Bash

Copy this text **exactly** to the top of every agent prompt, before any task-specific instructions. Orchestrators are responsible for injecting this prefix. An agent that receives a prompt without it will default to compound commands and have its calls rejected.

```
**CRITICAL — Bash discipline:** Compound bash commands (`&&`/`||`/`;`/`|`) are
HOOK-REJECTED in block mode. Every Bash tool call must contain exactly ONE
command. The ONLY exception is subshell `(cd dir && cmd)` for atomic cd+cmd.
Use `git -C <path>` for git operations. For multi-step shell logic, write a
script file and run it.
```

## Why this is mandatory

`COMPOUND_GUARD_MODE=block` is active in `settings.json`. The pre-tool hook exits non-zero before the command reaches the shell. There is no fallback — the prompt prefix is the only way to inform the agent of this constraint before its first Bash call.

## Related

- `bash-safety.md` — the parent rule
- `auto-delegation.md` — orchestrator responsibilities; Prefix 1 is this template
