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

2026-08-11 incident: a `gh issue comment --body "…"` call contained
unescaped backticks around `` `printenv` ``. The shell performed command
substitution **before** `gh` ran, splicing 92 environment variables —
including 14 live credentials — into a comment on a **public** GitHub repo.
Four provider keys were auto-revoked by scanners within minutes.

## When This Applies

Every Bash command. Enforced by `~/.claude/hooks/secret_leak_guard.sh`
(`PreToolUse:Bash`) — unlike most rules, this one does not depend on the
model remembering to be careful.

## CRITICAL: This Rule Is ENFORCED, Not Advisory

The hook parses `tool_input.command` and blocks (exit 2) before the shell
ever sees the command. A pure-bash substring fast-path rejects the common
case (no secret-related text at all) without spawning a subprocess; anything
that might match runs through exactly one `python3` invocation carrying all
six rules. `curl`/`aws`/`hf` are now fast-path trigger substrings too (Rule 6
needs to inspect their arguments), so a clean `curl`/`aws`/`hf` command now
always pays the one `python3` spawn where it previously never did — the
"nothing secret-related at all" case (e.g. `git status`, `Rscript -e ...`)
is unaffected and still never spawns a subprocess.

## The Six Rules

| # | Catches | Bypass |
|---|---------|--------|
| 1 | `gh (issue\|pr\|release\|gist\|api) ... --body/-b` containing a backtick or `$(` — the shell evaluates it before `gh` sees it | **None** — fix is trivial: use `--body-file <path>` |
| 2 | `echo`/`printf` in the same command segment as a `${NAME}` expansion where NAME matches `KEY\|TOKEN\|SECRET\|PASSWORD\|PASSWD\|PAT\|CREDENTIAL` (catches `echo "${VAR:+SET}${VAR:-UNSET}"` — `:-` yields the VALUE when set) | `SECRET_GUARD_BYPASS=1 ` prefix — see Bypass |
| 3 | A bare `printenv`/`env` (no argument, i.e. an actual dump) routed toward `gh `, `curl `, `\|`, `>`, or `tee`; or `printenv`/`env` appearing literally inside a `gh --body` argument | `SECRET_GUARD_BYPASS=1 ` prefix — see Bypass |
| 4 | A literal credential token in argv: `ghp_`/`gho_`/`ghs_`/`github_pat_`/`sk-ant-`/`sk-<20+ chars>`/`hf_<20+>`/`xoxb-`/`xoxp-`/`AIza<30+>`/`AKIA<16>`/`glpat-`/a PEM `-----BEGIN...PRIVATE KEY-----` block | **None** |
| 5 | The **contents** of a `gh (issue\|pr\|release\|gist\|api) ... --body-file <path>` file — same Rule-4 shape patterns, applied to what's actually in the file, not just the command string. `--body-file -` (stdin) is untouched here; Rule 3 already covers a piped dump into it. A missing/unreadable/directory/huge path fails OPEN (no block, no output) — capped at the first 256 KiB read | **None** — same rationale as Rule 4: a spliced credential is a spliced credential regardless of which side of `--body-file` it's read from |
| 6 | A high-entropy (Shannon entropy ≥ 3.0 bits/char, ≥16 chars, no vendor prefix) unprefixed value passed as an argument to `gh`/`curl`/`hf`/`aws` — the egress commands that actually send local data off the machine. Reuses `secret_exposure_scan.sh`'s entropy heuristic rather than growing Rule 4's prefix list (a prefix list only ever knows yesterday's vendors). Deliberately narrow: an entropy test over ALL argv would trip constantly on git SHAs, base64 blobs, nix store hashes, and UUIDs and get the guard disabled | `SECRET_GUARD_BYPASS=1 ` prefix — see Bypass; heuristic, will have false positives Rule 4 never does |

Rule 2's safe idiom is `[ -n "${VAR:-}" ] && echo set` — the expansion never
reaches an `echo`/`printf` argument, so it stays allowed. This is the
recommended pattern in `credential-management.md`.

Rule 6's entropy check excludes any token containing a `/` (paths and
relative `gh api owner/repo/...` endpoints are the single most common false
trigger), any token containing `%{` (curl's `-w`/`--write-out` format syntax,
e.g. `%{http_code} %{size_download}\n` — found in real use 2026-08-14: a
plain `curl -o <scratchpad-path> -w "%{http_code} %{size_download}\n" <url>`
was blocked because that `-w` token has entropy 4.196 bits/char and no
vendor prefix; the `-o` path token was already correctly excluded by the `/`
check), and any token that is entirely hex digits/hyphens (git SHAs, nix
store hashes, UUIDs) — see the `looks_like_credential_value()` docstring in
the hook source for the full exclusion list. It is intentionally scoped to
`gh`/`curl`/`hf`/`aws` only; a bare `echo` of an unprefixed high-entropy
value (the motivating example in llm#960 Part 2) is deliberately still
allowed — Rule 2 already covers the *named*-variable echo case, and widening
Rule 6 to non-egress commands was rejected as too wide a false-positive
surface for the observed incident class.

**Known blind spot:** these are *structural* exclusions (does this token look
like a path/URL/format-string?), not content inspection. A real secret that
happens to contain a `/`, a hex-only shape, or the literal substring `%{`
will evade Rule 6 the same way a legitimate path or curl format string does.
This is an accepted trade-off, not an oversight — the alternative (no
exclusions) reintroduced the original problem: an entropy test over every
argv token trips constantly on paths, SHAs, and format strings and gets the
whole guard disabled within a day (llm#960 Part 2). Rule 4's vendor-prefix
patterns have no such gap and remain unbypassable; Rule 6 is a heuristic
safety net for prefixless credentials, not a completeness guarantee.

## Bypass

For Rules 2, 3, and 6: prefix the **same command string** with
`SECRET_GUARD_BYPASS=1 `, e.g.
`SECRET_GUARD_BYPASS=1 curl -X POST -d wjqzxvkbmtynfcgh https://example.com`.
This is the **only** form a Bash-tool call can actually use: the hook parses
`tool_input.command` and decides BLOCK/ALLOW before any shell evaluates that
string, and shell state (an `export` made in one Bash call) does not persist
into a separate, later Bash call — so setting the real environment variable
from inside a session has no effect on the next command. The prefix is
recognised only in **command-prefix position**: at the very start of the
string, optionally after `env`, optionally after other `NAME=value`
assignments. It is NOT recognised as bare text anywhere later in the command
— `echo "SECRET_GUARD_BYPASS=1"`, or the string appearing inside a quoted
argument or after the command name, does **not** bypass anything. The
bypass is confined to Rules 2, 3, and 6 regardless of which form is used; it
never releases Rules 1, 4, or 5. The attempt is still logged (never silently
allowed) to `~/.claude/logs/secret_leak_guard_bypass.log`. Rules 1, 4, and 5
have **no** bypass by either form — a `--body-file` rewrite, removing a
literal credential from argv, or removing one from a body-file's contents is
always the correct fix, never a judgment call.

A real `SECRET_GUARD_BYPASS=1` environment variable set in the process that
launched the harness is also honoured (kept for compatibility), but an
ordinary Bash-tool caller has no way to set that.

## Logging

Every BLOCK appends one line to `~/.claude/logs/secret_leak_guard.log`: an
ISO-8601 UTC timestamp, the rule number, and the first 200 characters of the
offending command — with any Rule-4-shaped literal redacted to `<REDACTED>`
first. The log **never** contains an unredacted credential; that would
recreate the incident inside a log file.

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

## Egress-Matcher Coverage Beyond Bash

This guard covers `Bash` only. `Artifact` (publishes a page to a hosted URL)
and `WebFetch` (reads an external URL back into the transcript) also move
data out of the sandbox. Both are confirmed-working `PreToolUse` matchers
despite being absent from the documented matcher list (verified 2026-08-14
via deliberate probe invocations — undocumented is not evidence of
non-functional).

`~/.claude/hooks/artifact_secret_guard.sh` is a `PreToolUse:Artifact` hook
that applies Rule 5's logic (same credential-shape catalogue in
`~/.claude/hooks/lib/cred_patterns.py`, same 256 KiB read cap, same fail-open
behaviour, same no-bypass policy, same redaction discipline) to the file
named by `tool_input.file_path` before a publish is allowed. **VERIFIED
2026-08-21:** a live publish containing the fixture literal
`ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123` was rejected with no URL returned; a
clean control file published normally — the guard's JSON-deny mechanism is
confirmed-blocking on the `Artifact` matcher, not merely logging-and-hoping.
`WebFetch` has no equivalent content guard yet (llm#960 Part 3 remains open
for that tool). Full investigation history (matcher-fires probe, shape
probe, content-guard build and verification) is in the companion doc.

## Related

- [`_companions/secret-leak-prevention-details.md`](_companions/secret-leak-prevention-details.md)
  — full llm#960 Part 3 investigation: matcher-fires probe, shape probe,
  `artifact_secret_guard.sh` build + verification, split out of this rule
- `credential-management` rule — the broader retrieve-from-environment
  discipline this hook enforces at the shell layer; documents the same
  `:+`/`:-` anti-pattern
- `destructive-api-calls` / `destructive_api_guard.sh` — sibling
  `PreToolUse:Bash` hook for irreversible API calls (different failure
  class: destruction, not disclosure)
- `bash-safety` rule — general Bash command discipline
- `external-code-zero-trust` — Layer 4 (`gh_comment_provenance.sh`) reads
  comments *from* untrusted authors; this rule guards what we *write* to
  public surfaces
