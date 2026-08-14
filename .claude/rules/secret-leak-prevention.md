---
description: Hook-enforced guard against shell command-substitution / echo patterns that splice live credentials into a Bash command before it runs
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

## Egress-Matcher Feasibility Probe (llm#960 Part 3)

This guard covers `Bash`. Two other tools also move data out of the sandbox —
`Artifact` (publishes a page to a hosted URL) and `WebFetch` (reads an
external URL back into the transcript) — and Part 3 of
[llm#960](https://github.com/JohnGavin/llm/issues/960) asks whether a
content-inspecting guard, analogous to this one, can be extended to them.

The official Claude Code docs list `Bash`, `Edit`, `Write`, `Read`, `Glob`,
`Grep`, `Notebook*`, and `mcp__*` as `PreToolUse` matchers — `Artifact` and
`WebFetch` are absent from that list. **"Undocumented" is not evidence of
"non-functional."** `settings.json` already registers `Agent`, `Task`
(`PreToolUse` and `PostToolUse`), and `Skill` (`PostToolUse`) — none of which
appear in the documented list either — and all three demonstrably fire
(`agent_runs` rows in `~/.claude/logs/unified.duckdb` line up with real
dispatch timestamps; `skill_usage` is populated). Whether `Artifact` and
`WebFetch` match is an empirical question, not a documentation question, so
`settings.json` now carries two non-blocking `PreToolUse` observers —
matchers `Artifact` and `WebFetch`, both invoking the existing
`~/.claude/scripts/hook_event_emit.sh` directly (`hook_name` values
`artifact_probe` / `webfetch_probe`, `event_type` `PreToolUse:fired`) — so the
system answers the question itself instead of us guessing from docs.

### ANSWERED 2026-08-14 — both matchers fire

The probe resolved within minutes of landing, so the interpretation guidance
below is retained for the next matcher question rather than this one.

| Matcher | Evidence |
|---|---|
| `WebFetch` | `webfetch_probe` rows at `18:53:30Z` (a **subagent**'s fetch) and `22:06:06Z` (main session) |
| `Artifact` | `artifact_probe` row at `22:08:33Z` on a real publish |

Three things this settles, two of which contradict what was assumed here:

1. **Both are valid `PreToolUse` matchers**, despite neither appearing in the
   documented matcher list. A research pass had recommended treating them as
   unsupported *because* they were undocumented; that inference was wrong, in
   the same way it was wrong for `Agent`/`Task`/`Skill`.
2. **Hook config is read live, not cached at session start.** The `18:53:30Z`
   row predates any restart — it fired in a session that had already been
   running when `settings.json` changed. The claim that a restart was required
   (stated in the original commit for this section) was never tested.
3. The hook fires **before** the tool runs, so it fires even when the tool then
   fails — the `22:06:06Z` row came from a `WebFetch` that died on DNS
   resolution. That is correct `PreToolUse` semantics and means a guard here
   cannot be evaded by a call that was going to fail anyway.

**Therefore llm#960 Part 3 is feasible and unblocked**: a content-inspecting
guard on `Artifact` (the sharper of the two — it publishes to a hosted URL)
can be wired the same way Rule 5 inspects `--body-file`. The open question is
no longer *whether* the matcher fires but *what `tool_input` carries* — the
observers record no payload, so confirm a `file_path` (or equivalent) is
present before designing the guard around reading it.

**How to read the result** of a future matcher probe, once `hook_events_load.sh`
has drained the spool into `~/.claude/logs/unified.duckdb`:

- **Rows appear** for `hook_name = 'artifact_probe'` or `'webfetch_probe'` ⇒
  the matcher fires ⇒ a content-inspecting guard on that tool (mirroring this
  file's Four Rules) is feasible, and llm#960 Part 3 can proceed.
- **No rows after a day of normal use ⇒ inconclusive, NOT proof the matcher
  doesn't work.** Absence of rows is equally consistent with "the matcher
  doesn't fire" and "neither tool was invoked all day." Do not conclude
  non-matchability from a silent table — first confirm the tool actually ran
  during the observation window (check whether any session that day actually
  called `Artifact` or `WebFetch` at all) before treating silence as a
  negative result. A silent table misread as "doesn't work" is the same
  false-negative trap that let 27 rules drift out of `RULES.md` unnoticed —
  verify use before drawing a conclusion from absence.

Confirming the tool actually ran is harder than it looks, and is the step most
likely to be skipped: if the matcher does not fire there is, by construction, no
record that the tool was used, so the two hypotheses leave identical evidence.
Do not wait for incidental use. **Deliberately invoke each tool once in a fresh
session** (publish a throwaway Artifact; fetch any URL with `WebFetch`), note the
time, and check for rows at that timestamp. One confirmed invocation with no
matching row is a real negative; a quiet day is not. Note also that the spool
only drains into `unified.duckdb` on the nightly 02:00 ETL, so check
`~/.claude/logs/hook_events_staging.jsonl` directly if you want the answer the
same day.

Query once data exists:

```sql
SELECT hook_name, event_type, count(*) AS n, max(fired_at) AS last_seen
FROM hook_events
WHERE hook_name IN ('artifact_probe', 'webfetch_probe')
GROUP BY hook_name, event_type;
```

## Related

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
