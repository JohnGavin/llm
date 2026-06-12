---
description: Permission mode binding, MCP tool classification, environment declaration, credential discovery policy
paths:
  - ".claude/settings*.json"
  - ".claude/hooks/**"
  - "**/.mcp.json"
---

# Rule: Permission and Security Discipline

Consolidated from: `permission-mode-discipline`, `mcp-destructive-scope`, `prod-staging-context-guard`, `secret-discovery-policy`.

Source: PocketOS / Cursor / Railway incident 2026-04-25.

---

## Part 1: Permission Mode Binding

### CRITICAL: bypassPermissions Only in Isolated Workspaces

| Workspace | Permission mode |
|---|---|
| `~/docs_gh/<project>/` (main checkout) | `default` |
| `/tmp/*`, `/private/tmp/*` | `bypassPermissions` |
| Sibling worktree | `bypassPermissions` |

Detection: checkout is a **worktree** iff `git rev-parse --git-common-dir` ≠ `git rev-parse --git-dir`.

### Enforcement

1. Wrapper script `~/.claude/scripts/cc.sh` selects mode based on cwd
2. `session_init.sh` Phase 1b reports expected mode

### Forbidden

| Pattern | Why wrong |
|---|---|
| `claude --permission-mode bypassPermissions` from main checkout | Lives next to live tokens |
| Setting `defaultMode: bypassPermissions` globally | Default is the failure mode |

---

## Part 2: MCP Tool Classification

### CRITICAL: Classify Before Wiring; Default to Destructive

| Tier | Meaning | Approval |
|---|---|---|
| `read` | Queries only, no side effects | Auto-approve |
| `write` | Creates/modifies state, reversible | Per-session |
| `destructive` | Deletes, hangs session | Per-call OR disabled |

### Current MCP Table

| MCP | Read | Write | Destructive |
|---|---|---|---|
| r-btw | `docs_*`, `files_list/read/search`, `sessioninfo_*`, `env_describe_*` | `files_write` | `run_r`, `pkg_*` (hang risk — use Bash+timeout) |
| Gmail/Calendar/Drive | — | — | Auth stubs only; inactive |
| markitdown-mcp | `convert_to_markdown` (file path → markdown text; no side effects on source) | — (if a write-to-disk variant is exposed, classify as **write** and require per-session approval) | No auth token; local execution only. No destructive tools identified in upstream README. |

### Pre-Install Checklist

- [ ] Inventory full tool list
- [ ] Classify each as read/write/destructive
- [ ] Document in this rule's table
- [ ] Verify auth-token scope at provider
- [ ] Test in scratch workspace first

---

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

---

## Part 4: Credential Discovery Policy

### CRITICAL: Discovery Is Not Authorisation

Before using any discovered credential:
1. Name the file path it came from
2. Name the intended operation
3. Confirm in `SECRETS.md` OR ask user

### Decision Table

| Discovery path | Action |
|---|---|
| Env var passed at session start | Use; mention var and operation |
| `.Renviron` for assigned task | Use; mention var and operation |
| Token in file being edited | Use; in scope |
| Token found via grep of unrelated file | **STOP. Ask user.** |
| Token not in `SECRETS.md` | **STOP. Verify scope.** |

### Forbidden

| Pattern | Why wrong |
|---|---|
| Grep finds token, use silently | Discovery ≠ authorisation |
| Use token for DELETE without mentioning | Scope may exceed intent |
| Assume `*_READ_KEY` is read-only | Names not enforced by providers |

---

## Related

- `destructive-ops-guard` — hook-level blocking, recovery trails
- `bash-safety` — compound commands, safe deletion
- `btw-timeouts` — r-btw specific timeout requirements
