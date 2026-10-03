# Rule: Permission and Security Discipline

## Safety-Critical Tier — Loads Unconditionally (No `paths:`)

Per [llm#943](https://github.com/JohnGavin/llm/issues/943), this rule is in the **safety-critical tier** declared in AGENTS.md and carries no `paths:` frontmatter, so it loads into every session and subagent (permission decisions happen on any Bash call). Consolidated from `permission-mode-discipline`, `mcp-destructive-scope`, `prod-staging-context-guard`, `secret-discovery-policy`. Source: PocketOS / Cursor / Railway incident 2026-04-25.

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
| markitdown-mcp | `convert_to_markdown` (no side effects on source) | — (a write-to-disk variant would be **write**: per-session approval) | None identified; no auth token, local execution only |

### Pre-Install Checklist

Before wiring an MCP: inventory its tools, classify each read/write/destructive, document it in the table above, verify auth-token scope at the provider, test in a scratch workspace.

### Known Gap: no `PreToolUse` content guard on `mcp__*` (llm#996, 2026-08-29)

No `PreToolUse` hook matches `mcp__*` — a known, deliberate, tracked gap (the matcher is unverified; only `mcp__r-btw__btw_tool_files_write` is `write`-tier); probe-then-guard is the next step. Rationale and trigger condition: companion doc.

## Part 3: Environment Declaration

Every project's `.claude/CLAUDE.md` SHOULD declare `| Environment | <value> |` with one of `research` (exploratory, no live users; default if unspecified), `dev` (tooling, config, packages), `prod` (live service, published website), `mixed` (both). Project audit (`llm` dev; `JohnGavin.github.io` and `llmtelemetry` prod; `randomwalk`, `irishbuoys`, `mycare`, `footbet` research): companion doc.

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

## Related

- `destructive-ops-guard` — hook-level blocking, recovery trails
- `bash-safety` — compound commands, safe deletion
- `btw-timeouts` — r-btw specific timeout requirements
