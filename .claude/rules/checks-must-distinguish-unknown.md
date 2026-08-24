---
description: Any check, gate, probe or health report must be able to say "I could not determine this" distinguishably from a negative or all-clear result — an error path and a negative-result path must never share an exit
paths:
  - ".claude/scripts/**"
  - ".claude/hooks/**"
  - "bin/**"
  - ".github/workflows/**"
  - "R/**"
---

# Rule: A Check Must Be Able to Say "I Don't Know"

## When This Applies

Anything whose output is used to decide something: a merge gate, a health
report, a freshness probe, a liveness check, a CI conditional, a completion
check in a runbook, a monitor's terminal condition, a validation target. If a
human or a script will read its result and act, this rule applies.

## CRITICAL: Never let "I could not answer" exit the same way as "the answer is no"

A check has at least three possible states, and most implementations collapse
them into two:

| state | meaning | must be |
|---|---|---|
| **positive** | found the thing / it is broken | reported |
| **negative** | looked, did not find it / it is fine | reported |
| **indeterminate** | could not look — tool missing, auth failed, path wrong, timeout, empty input | **reported distinctly, never as negative** |

When indeterminate collapses into negative, the check reports good news
precisely when it is least entitled to. It is silent exactly when something is
wrong with the checking apparatus itself, which is the moment you most need to
hear from it.

## The signature to look for

```bash
result=$(some_command 2>/dev/null || true)
[ -z "$result" ] && return 0        # "nothing found" — or "could not ask"
```

Three constructs, each individually defensible, that together erase the
distinction:

- `2>/dev/null` — discards the reason
- `|| true` — discards the exit status
- `[ -z "$result" ]` — treats empty as a negative answer

## Worked instances

Six in one week in this repo, all the same defect wearing different clothes:

| issue | the check | what it said | why it was blind |
|---|---|---|---|
| [#1012](https://github.com/JohnGavin/llm/issues/1012) | roborev merge gate | `PASS` | resolved `gh` from `/usr/local/bin/gh`, which does not exist |
| [#746](https://github.com/JohnGavin/llm/issues/746) | `roborev check-agents` | `claude-code OK` | used the caller's PATH, not the daemon's |
| [#913](https://github.com/JohnGavin/llm/issues/913) | freshness probe | `fresh` | ran inside the writer's own code path |
| [#1013](https://github.com/JohnGavin/llm/issues/1013) | rotation completion check | `0` | `grep -c '^export'` on a file with no `export` lines |
| [#1017](https://github.com/JohnGavin/llm/issues/1017) | hook liveness report | `never fired` | counted emitter calls, not executions |
| [#1019](https://github.com/JohnGavin/llm/issues/1019) | GC squash detection | `not merged` | `gh` 401 swallowed into an empty result |

[#1019](https://github.com/JohnGavin/llm/issues/1019) is the clearest: identical
command, two environments.

```
$ gh pr list -R … --head worktree-agent-…        →  HTTP 401: Bad credentials
$ env -u GH_TOKEN gh pr list -R … --head …       →  [{"number":1006}]
```

The GC saw the first as "no merged PR exists" and retained ~5 GB of
already-merged worktrees indefinitely.

[#1013](https://github.com/JohnGavin/llm/issues/1013) is the most instructive:
`grep -c '^export' ~/.config/secrets.env # expect 13` returns `0` for a healthy
file **and** `0` for an empty one. Its output does not vary with the thing it
measures. That is not a weak check; it is not a check.

## Required pattern

Capture the status. Branch on it. Say so.

```bash
result=$(some_command 2>"$err_file"); rc=$?
if [ "$rc" -ne 0 ]; then
    log "INDETERMINATE: <check> could not run (rc=$rc): $(head -c 200 "$err_file")"
    return 2          # distinct from both 0 (clear) and 1 (finding)
fi
if [ -z "$result" ]; then
    log "CLEAR: <check> ran, found nothing"
    return 0
fi
```

Exit-code convention for new checks:

| code | meaning |
|---|---|
| `0` | ran; clear |
| `1` | ran; found something |
| `2` | **could not run** — do not interpret as either |

Where fail-safe behaviour requires continuing anyway (a GC that retains rather
than deletes, a gate that permits rather than blocks), **still log the
indeterminate state loudly**. Fail-safe is about the action taken; it is not a
licence to be silent about why.

## Reporting requirement

A summary line that aggregates checks must carry the indeterminate count
alongside the others. `would-remove-squash=0` meant both "nothing to remove"
and "I could not check" — one number, two meanings, no way to tell them apart.

```
checks=42 clear=38 findings=2 indeterminate=2      # good
checks=42 clear=40 findings=2                      # hides the failure mode
```

Same for dashboards and health emails: a column that cannot render "unknown"
will render "fine".

## Self-test requirement

Every check ships a test that runs it with its dependency **broken** and asserts
the output is not an all-clear:

```bash
# the tool is absent
GH=/nonexistent/gh    run_check   # must NOT print PASS
# the credential is invalid
GH_TOKEN=invalid      run_check   # must NOT print PASS
```

Without this the failure mode is invisible by construction — the check passes
its own tests precisely because the tests supply a working environment.

## Forbidden patterns

| Pattern | Why wrong | Fix |
|---|---|---|
| `cmd 2>/dev/null \|\| true` feeding an emptiness test | Error and negative become the same value | Capture `rc`, branch on it |
| Hardcoded absolute tool path with no existence check | Missing tool degrades to "found nothing" | Resolve from PATH; error if unresolvable |
| A check whose output cannot vary with its subject | Not a check | Verify it fails when it should |
| Verifying on a surface other than where the thing is consumed | Passes locally, broken in the consumer | Verify where it runs |
| A probe called from inside the producer it measures | Measures its own liveness | Separate trigger class |
| Summary counters with no indeterminate column | "Could not check" renders as zero | Add the column |
| Treating exit code 0 from a restart/reload as proof it happened | Command success ≠ effect | Compare observable state before/after |

## Self-check before shipping any check

> **If the thing I depend on were broken right now, what would this print?**

If the answer is "the same thing it prints when everything is fine", it is not
finished.

## Related

- [`verification-before-completion`](verification-before-completion.md) — do not claim without fresh evidence; this rule is the converse (do not let absent evidence read as good evidence)
- [`systematic-debugging`](systematic-debugging.md) — "Measure the baseline"; a check that cannot fail has no baseline
- [`probe-must-not-share-writer-path`](../memory/probe-must-not-share-writer-path.md) — the special case where the probe shares the producer's code path
- [`health-check-inherits-a-different-path`](../memory/health-check-inherits-a-different-path.md) — the special case where the check inherits the wrong environment
- [`feedback_fixtures-hide-boundary-drift`](../memory/feedback_fixtures-hide-boundary-drift.md) — the special case where the test fixture sits too far from the boundary to exercise it
- Origin: six instances 2026-08-18 → 2026-08-24, listed above
