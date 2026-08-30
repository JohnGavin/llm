# Companion: Secret Leak Prevention — Egress-Matcher Feasibility Investigation + Extended Rule Detail

Dated investigation narrative and verbose rule-tuning detail split out of the
always-loaded [`secret-leak-prevention`](../secret-leak-prevention.md) rule
to keep it under the repo's line-count budget. The normative content (Source,
CRITICAL statement, The Six Rules table, Bypass mechanism, Logging,
Forbidden Patterns table, the Artifact Publish Guard summary, Related) stays
in the rule; this file is the full llm#960 Part 3 investigation history and
extended rule-exclusion rationale, loaded on demand.

## Rule 6 — full exclusion detail

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

**Known blind spot, full rationale:** these are *structural* exclusions
(does this token look like a path/URL/format-string?), not content
inspection. A real secret that happens to contain a `/`, a hex-only shape,
or the literal substring `%{` will evade Rule 6 the same way a legitimate
path or curl format string does. This is an accepted trade-off, not an
oversight — the alternative (no exclusions) reintroduced the original
problem: an entropy test over every argv token trips constantly on paths,
SHAs, and format strings and gets the whole guard disabled within a day
(llm#960 Part 2). Rule 4's vendor-prefix patterns have no such gap and
remain unbypassable; Rule 6 is a heuristic safety net for prefixless
credentials, not a completeness guarantee.

## Egress-Matcher Feasibility Probe (llm#960 Part 3) — full investigation

This guard covers `Bash`. Two other tools also move data out of the sandbox
— `Artifact` (publishes a page to a hosted URL) and `WebFetch` (reads an
external URL back into the transcript) — and Part 3 of
[llm#960](https://github.com/JohnGavin/llm/issues/960) asked whether a
content-inspecting guard, analogous to this one, could be extended to them.

The official Claude Code docs list `Bash`, `Edit`, `Write`, `Read`, `Glob`,
`Grep`, `Notebook*`, and `mcp__*` as `PreToolUse` matchers — `Artifact` and
`WebFetch` are absent from that list. **"Undocumented" is not evidence of
"non-functional."** `settings.json` already registers `Agent`, `Task`
(`PreToolUse` and `PostToolUse`), and `Skill` (`PostToolUse`) — none of which
appear in the documented list either — and all three demonstrably fire
(`agent_runs` rows in `~/.claude/logs/unified.duckdb` line up with real
dispatch timestamps; `skill_usage` is populated). Whether `Artifact` and
`WebFetch` match was an empirical question, not a documentation question, so
`settings.json` was given two non-blocking `PreToolUse` observers — matchers
`Artifact` and `WebFetch`, both invoking `~/.claude/scripts/hook_event_emit.sh`
directly (`hook_name` values `artifact_probe` / `webfetch_probe`, `event_type`
`PreToolUse:fired`) — so the system answered the question itself instead of
guessing from docs.

### ANSWERED 2026-08-14 — both matchers fire

The probe resolved within minutes of landing.

| Matcher | Evidence |
|---|---|
| `WebFetch` | `webfetch_probe` rows at `18:53:30Z` (a **subagent**'s fetch) and `22:06:06Z` (main session) |
| `Artifact` | `artifact_probe` row at `22:08:33Z` on a real publish |

Three things this settled, two of which contradicted what was assumed:

1. **Both are valid `PreToolUse` matchers**, despite neither appearing in the
   documented matcher list. A research pass had recommended treating them as
   unsupported *because* they were undocumented; that inference was wrong, in
   the same way it was wrong for `Agent`/`Task`/`Skill`.
2. **Hook config is read live, not cached at session start.** The `18:53:30Z`
   row predates any restart — it fired in a session that had already been
   running when `settings.json` changed. The claim that a restart was
   required (stated in the original commit for this section) was never
   tested.
3. The hook fires **before** the tool runs, so it fires even when the tool
   then fails — the `22:06:06Z` row came from a `WebFetch` that died on DNS
   resolution. That is correct `PreToolUse` semantics and means a guard here
   cannot be evaded by a call that was going to fail anyway.

**Conclusion: llm#960 Part 3 was feasible and unblocked** — a
content-inspecting guard on `Artifact` (the sharper of the two — it
publishes to a hosted URL) could be wired the same way Rule 5 inspects
`--body-file`. The open question was no longer *whether* the matcher fires
but *what `tool_input` carries* — the observers recorded no payload, so the
next step was confirming a `file_path` (or equivalent) was present before
designing the guard around reading it.

### Shape probe replaces the bare observers (2026-08-16)

The two `PreToolUse` entries above were switched to call
`~/.claude/hooks/tool_input_probe.sh <hook_name>` instead of
`hook_event_emit.sh` directly. The new script reads `tool_input` and emits
one `hook_events` row recording its **shape only**: sorted top-level key
names, each key's JSON type, and — for strings — its length (e.g.
`keys=[description=string:23,favicon=string:5,file_path=string:16,
title=string:11,file_path_exists=False]`). It never records a value, a
substring of a value, or file contents; `file_path` additionally gets an
existence check (`file_path_exists=True/False`) against the path it names,
without ever opening what the path points at. `hook_name` values
(`artifact_probe` / `webfetch_probe`) are unchanged, so existing rows stay
comparable across the switchover. Selftest: `bash
~/.claude/hooks/tool_input_probe.sh --selftest` (7 cases, including a
sentinel-value proof that no value ever reaches the emitted row).

This did not yet answer the open question above — it only sharpened it. It
needed a real `Artifact` publish after this change merged to confirm which
keys `tool_input` actually carries in production (the design assumed
`file_path` is present; that assumption was unverified until a live row
showed it — see the "VERIFIED 2026-08-21" entry below, which confirmed it).

**How to read the result** of a future matcher probe, once
`hook_events_load.sh` has drained the spool into
`~/.claude/logs/unified.duckdb`:

- **Rows appear** for `hook_name = 'artifact_probe'` or `'webfetch_probe'` ⇒
  the matcher fires ⇒ a content-inspecting guard on that tool (mirroring the
  Six Rules) is feasible.
- **No rows after a day of normal use ⇒ inconclusive, NOT proof the matcher
  doesn't work.** Absence of rows is equally consistent with "the matcher
  doesn't fire" and "neither tool was invoked all day." Do not conclude
  non-matchability from a silent table — first confirm the tool actually ran
  during the observation window (check whether any session that day actually
  called `Artifact` or `WebFetch` at all) before treating silence as a
  negative result. A silent table misread as "doesn't work" is the same
  false-negative trap that let 27 rules drift out of `RULES.md` unnoticed —
  verify use before drawing a conclusion from absence.

Confirming the tool actually ran is harder than it looks, and is the step
most likely to be skipped: if the matcher does not fire there is, by
construction, no record that the tool was used, so the two hypotheses leave
identical evidence. Do not wait for incidental use — deliberately invoke each
tool once in a fresh session (publish a throwaway Artifact; fetch any URL
with `WebFetch`), note the time, and check for rows at that timestamp. One
confirmed invocation with no matching row is a real negative; a quiet day is
not. Note also that the spool only drains into `unified.duckdb` on the
nightly 02:00 ETL, so check `~/.claude/logs/hook_events_staging.jsonl`
directly if you want the answer the same day.

Query once data exists:

```sql
SELECT hook_name, event_type, count(*) AS n, max(fired_at) AS last_seen
FROM hook_events
WHERE hook_name IN ('artifact_probe', 'webfetch_probe')
GROUP BY hook_name, event_type;
```

### Content guard on `Artifact` publishes (llm#960 Part 3, 2026-08-16)

`~/.claude/hooks/artifact_secret_guard.sh` is a `PreToolUse:Artifact` hook
that reads the file named by `tool_input.file_path` (proven present by a
real 2026-08-16 publish — see "ANSWERED 2026-08-14" above) and blocks the
publish if the file's contents contain a literal credential shape. It is
Rule 5 (`--body-file` contents) pointed at a different input source: same
credential-shape catalogue, same 256 KiB read cap, same fail-open behaviour
on a missing/unreadable/directory path, same no-bypass policy, same
redaction discipline (file + line number + credential *description* only —
never the matched value). It runs **alongside** `tool_input_probe.sh` on the
`Artifact` matcher, not in place of it — `settings.json` already carries six
separate hooks on the `Bash` matcher, so a second, differently-scoped hook on
`Artifact` (telemetry shape probe vs. content security guard) follows an
established pattern rather than inventing one.

**Single source of truth for the pattern catalogue.** `CRED_PATTERNS`
previously lived only inside `secret_leak_guard.sh`'s embedded python
heredoc. It now lives in `~/.claude/hooks/lib/cred_patterns.py`, imported by
BOTH `secret_leak_guard.sh` (Rules 4/5) and `artifact_secret_guard.sh` — never
redefined in either. `artifact_secret_guard.sh --selftest` asserts the
pattern definitions appear in exactly one file under `.claude/hooks/**`
(mirroring `rotate_secret.sh`'s "each `CONSUMERS_*` name defined exactly
once" check from llm#958, applied to this catalogue instead of the consumer
map) — a regression guard against the exact duplication llm#958 was raised
to fix. `secret_leak_guard.sh --selftest` was re-run after the extraction and
is still 53/53 — the regression proof that Rules 1-6 are unaffected by moving
their shared data out of the file.

**VERIFIED 2026-08-21 (llm#960 dispatch 015ee83e): the JSON-deny block
mechanism actually stops a real `Artifact` publish.** For `Bash`, blocking is
exit 2. The documented mechanism for non-Bash `PreToolUse` matchers is exit 0
plus a JSON body on stdout (`hookSpecificOutput.permissionDecision = "deny"`),
and that is what `artifact_secret_guard.sh` emits — chosen because it is the
one with documented support for tools other than `Bash`; exit 2 is documented
specifically for `Bash`.

Two live `Artifact` calls confirmed both directions:
- A file containing the fixture literal `ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123`
  (the same literal the selftest uses) was rejected with the tool call
  itself returning the guard's `BLOCKED (artifact_secret_guard): ...` message
  — no page was published, no URL was returned.
- A clean control file with no credential-shaped content published
  successfully (`https://claude.ai/code/artifact/...` returned), confirming
  the guard is not fail-closed on everything.

This closed the open question: the JSON-deny form is confirmed-blocking, not
merely logging-and-attempting-to-block. The selftest already proved the
guard's own logic (detection, fail-open paths, redaction, dedup); this
confirmed Claude Code actually honours the JSON it emits on the `Artifact`
matcher specifically.
