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
four rules.

## The Four Rules

| # | Catches | Bypass |
|---|---------|--------|
| 1 | `gh (issue\|pr\|release\|gist\|api) ... --body/-b` containing a backtick or `$(` — the shell evaluates it before `gh` sees it | **None** — fix is trivial: use `--body-file <path>` |
| 2 | `echo`/`printf` in the same command segment as a `${NAME}` expansion where NAME matches `KEY\|TOKEN\|SECRET\|PASSWORD\|PASSWD\|PAT\|CREDENTIAL` (catches `echo "${VAR:+SET}${VAR:-UNSET}"` — `:-` yields the VALUE when set) | `SECRET_GUARD_BYPASS=1` |
| 3 | A bare `printenv`/`env` (no argument, i.e. an actual dump) routed toward `gh `, `curl `, `\|`, `>`, or `tee`; or `printenv`/`env` appearing literally inside a `gh --body` argument | `SECRET_GUARD_BYPASS=1` |
| 4 | A literal credential token in argv: `ghp_`/`gho_`/`ghs_`/`github_pat_`/`sk-ant-`/`sk-<20+ chars>`/`hf_<20+>`/`xoxb-`/`xoxp-`/`AIza<30+>`/`AKIA<16>`/`glpat-`/a PEM `-----BEGIN...PRIVATE KEY-----` block | **None** |

Rule 2's safe idiom is `[ -n "${VAR:-}" ] && echo set` — the expansion never
reaches an `echo`/`printf` argument, so it stays allowed. This is the
recommended pattern in `credential-management.md`.

## Bypass

For Rules 2 and 3 only: set `SECRET_GUARD_BYPASS=1` on the command. The
attempt is still logged (never silently allowed) to
`~/.claude/logs/secret_leak_guard_bypass.log`. Rules 1 and 4 have **no**
bypass — a `--body-file` rewrite or removing a literal credential from argv
is always the correct fix, never a judgment call.

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

**How to read the result**, once `hook_events_load.sh` has drained the spool
into `~/.claude/logs/unified.duckdb`:

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
