---
description: Hook-enforced guard against shell command-substitution / echo patterns that splice live credentials into a Bash command before it runs
scoping-justification: enforced by secret_leak_guard.sh (a PreToolUse:Bash hook, not advisory LLM recall) — the hook fires on every Bash call regardless of what this rule text loads for, so it does not need the mandatory/safety-critical "never scoped" contract; see llm#943 item 3
paths:
  - ".claude/hooks/**"
  - ".claude/scripts/**"
  - "bin/**"
  - "**/*.sh"
  - "**/.zshenv"
  - "**/.zshrc"
  - "**/secrets.env"
  - "**/.Renviron*"
  - ".github/**"
---

# Rule: Secret Leak Prevention (Enforced)

## Source

2026-08-11 incident: a `gh issue comment --body "…"` call contained unescaped backticks around `` `printenv` ``. The shell performed command substitution **before** `gh` ran, splicing 92 environment variables — including 14 live credentials — into a comment on a **public** GitHub repo. Four provider keys were auto-revoked by scanners within minutes.

## When This Applies

Every Bash command. Enforced by `~/.claude/hooks/secret_leak_guard.sh` (`PreToolUse:Bash`) — unlike most rules, this one does not depend on the model remembering to be careful.

## CRITICAL: This Rule Is ENFORCED, Not Advisory

The hook parses `tool_input.command` and blocks (exit 2) before the shell ever sees the command. A pure-bash substring fast-path rejects the common case (no secret-related text at all) without spawning a subprocess; anything that might match runs through exactly one `python3` invocation carrying all six rules. `curl`/`aws`/`hf` are now fast-path trigger substrings too (Rule 6 needs to inspect their arguments), so a clean `curl`/`aws`/`hf` command now always pays the one `python3` spawn where it previously never did — the "nothing secret-related at all" case (e.g. `git status`, `Rscript -e ...`) is unaffected and still never spawns a subprocess.

## The Six Rules

| # | Catches | Bypass |
|---|---------|--------|
| 1 | `gh (issue\|pr\|release\|gist\|api) ... --body/-b` containing a backtick or `$(` — the shell evaluates it before `gh` sees it | **None** — fix is trivial: use `--body-file <path>` |
| 2 | `echo`/`printf` in the same command segment as a `${NAME}` expansion where NAME matches `KEY\|TOKEN\|SECRET\|PASSWORD\|PASSWD\|PAT\|CREDENTIAL` (catches `echo "${VAR:+SET}${VAR:-UNSET}"` — `:-` yields the VALUE when set) | `SECRET_GUARD_BYPASS=1 ` prefix — see Bypass |
| 3 | A bare `printenv`/`env` (no argument, i.e. an actual dump) routed toward `gh `, `curl `, `\|`, `>`, or `tee`; or `printenv`/`env` appearing literally inside a `gh --body` argument | `SECRET_GUARD_BYPASS=1 ` prefix — see Bypass |
| 4 | A literal credential token in argv: `ghp_`/`gho_`/`ghs_`/`github_pat_`/`sk-ant-`/`sk-<20+ chars>`/`hf_<20+>`/`xoxb-`/`xoxp-`/`AIza<30+>`/`AKIA<16>`/`glpat-`/a PEM `-----BEGIN...PRIVATE KEY-----` block | **None** |
| 5 | The **contents** of a `gh (issue\|pr\|release\|gist\|api) ... --body-file <path>` file — same Rule-4 shape patterns, applied to what's actually in the file, not just the command string. `--body-file -` (stdin) is untouched here; Rule 3 already covers a piped dump into it. A missing/unreadable/directory/huge path fails OPEN (no block, no output) — capped at the first 256 KiB read | **None** — same rationale as Rule 4: a spliced credential is a spliced credential regardless of which side of `--body-file` it's read from |
| 6 | A high-entropy (Shannon entropy ≥ 3.0 bits/char, ≥16 chars, no vendor prefix) unprefixed value passed as an argument to `gh`/`curl`/`hf`/`aws` — the egress commands that actually send local data off the machine. Reuses `secret_exposure_scan.sh`'s entropy heuristic rather than growing Rule 4's prefix list (a prefix list only ever knows yesterday's vendors). Deliberately narrow: an entropy test over ALL argv would trip constantly on git SHAs, base64 blobs, nix store hashes, and UUIDs and get the guard disabled | `SECRET_GUARD_BYPASS=1 ` prefix — see Bypass; heuristic, will have false positives Rule 4 never does |

Rule 2's safe idiom is `[ -n "${VAR:-}" ] && echo set` — the expansion never reaches an `echo`/`printf` argument, so it stays allowed. This is the recommended pattern in `credential-management.md`.

Rule 6 excludes path-shaped, curl-format-shaped, and hex-only tokens (git SHAs/nix hashes/UUIDs) to avoid the false-positive storm a raw entropy-over-all-argv test produces; scoped to `gh`/`curl`/`hf`/`aws` only — a bare `echo` of an unprefixed high-entropy value is deliberately still allowed (Rule 2 covers the named-variable case). Full exclusion list and worked false-positive case: companion doc.

**Known blind spot:** these are *structural* exclusions (does this token look like a path/URL/format-string?), not content inspection — a real secret with a `/`, a hex-only shape, or `%{` evades Rule 6 the same way a legitimate path or format string does. This is an accepted trade-off, not an oversight (the alternative — no exclusions — gets the whole guard disabled within a day, llm#960 Part 2). Rule 4's vendor-prefix patterns have no such gap and remain unbypassable. Full rationale: companion doc.

## Bypass

For Rules 2, 3, and 6: prefix the **same command string** with `SECRET_GUARD_BYPASS=1 `, e.g. `SECRET_GUARD_BYPASS=1 curl -X POST -d wjqzxvkbmtynfcgh https://example.com`. This is the **only** form a Bash-tool call can actually use: the hook parses `tool_input.command` and decides BLOCK/ALLOW before any shell evaluates that string, and shell state (an `export` made in one Bash call) does not persist into a separate, later Bash call — so setting the real environment variable from inside a session has no effect on the next command. The prefix is recognised only in **command-prefix position**: at the very start of the string, optionally after `env`, optionally after other `NAME=value` assignments. It is NOT recognised as bare text anywhere later in the command — `echo "SECRET_GUARD_BYPASS=1"`, or the string appearing inside a quoted argument or after the command name, does **not** bypass anything. The bypass is confined to Rules 2, 3, and 6 regardless of which form is used; it never releases Rules 1, 4, or 5. The attempt is still logged (never silently allowed) to `~/.claude/logs/secret_leak_guard_bypass.log`. Rules 1, 4, and 5 have **no** bypass by either form — a `--body-file` rewrite, removing a literal credential from argv, or removing one from a body-file's contents is always the correct fix, never a judgment call.

A real `SECRET_GUARD_BYPASS=1` environment variable set in the process that launched the harness is also honoured (kept for compatibility), but an ordinary Bash-tool caller has no way to set that.

## Logging

Every BLOCK appends one line to `~/.claude/logs/secret_leak_guard.log`: an ISO-8601 UTC timestamp, the rule number, and the first 200 characters of the offending command — with any Rule-4-shaped literal redacted to `<REDACTED>` first. The log **never** contains an unredacted credential; that would recreate the incident inside a log file.

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---------|-----------|-----|
| `` gh issue comment N --body "... `cmd` ..." `` | Shell runs `cmd` before `gh` does, splicing its output into a public comment | `gh issue comment N --body-file /tmp/body.md` |
| `gh pr create --body "$(some_cmd)"` | Same command-substitution hazard | Write the body to a file first |
| `echo "${VAR:+SET}${VAR:-UNSET}"` as an is-it-set check | `:-` expands to the value when `VAR` is set — prints the secret | `[ -n "${VAR:-}" ] && echo set` |
| `printenv \| gh ... --body-file -` | Dumps every env var into a `gh` argument | Never pipe `printenv`/`env` into anything that leaves the shell |
| Hardcoding a token literal in a curl/gh command for "quick testing" | Committed to shell history, logs, and possibly git | `Sys.getenv()` / `${VAR}` from `.Renviron` / CI secrets — see `credential-management.md` |
| `Write /tmp/body.md` (containing a credential) then `gh issue comment N --body-file /tmp/body.md` | Rule 1 tells you to use `--body-file`; obeying that advice with a credential still in the file used to sail straight through uninspected | Rule 5 now reads the file's contents before allowing the command |
| `curl -d "$UNPREFIXED_APP_PASSWORD" https://api.example.com` where the value has no vendor prefix (e.g. a 16-char Gmail app password) | Rule 4 only matches enumerated vendor prefixes; a prefixless credential passed to an egress command was invisible | Rule 6's entropy check catches it; if it's a genuine false positive, retry with a `SECRET_GUARD_BYPASS=1 ` prefix — see Bypass |

## Artifact Publish Guard (llm#960 Part 3)

`~/.claude/hooks/artifact_secret_guard.sh` is a `PreToolUse:Artifact` hook mirroring Rule 5's pattern but pointed at `tool_input.file_path` instead of a `--body-file` argument: same credential-shape catalogue (`~/.claude/hooks/lib/cred_patterns.py`, the single source of truth shared with `secret_leak_guard.sh` Rules 4/5), same 256 KiB read cap, same fail-open behaviour on a missing/unreadable/directory path, same no-bypass policy, same redaction discipline. **Confirmed blocking in production 2026-08-21**: a live `Artifact` publish containing a fixture credential literal was rejected before a URL was returned; a clean control file published normally. Blocking uses the JSON-deny `PreToolUse` mechanism (`hookSpecificOutput.permissionDecision = "deny"`) rather than exit 2, since exit 2 is documented specifically for `Bash`. Full investigation history (the `WebFetch`/`Artifact` matcher-feasibility probe that preceded this guard, and the methodology for probing any future undocumented matcher): companion doc.

## Related

- `credential-management` rule — the broader retrieve-from-environment discipline this hook enforces at the shell layer; documents the same `:+`/`:-` anti-pattern
- `destructive-api-calls` / `destructive_api_guard.sh` — sibling `PreToolUse:Bash` hook for irreversible API calls (different failure class: destruction, not disclosure)
- `bash-safety` rule — general Bash command discipline
- `external-code-zero-trust` — Layer 4 (`gh_comment_provenance.sh`) reads comments *from* untrusted authors; this rule guards what we *write* to public surfaces
