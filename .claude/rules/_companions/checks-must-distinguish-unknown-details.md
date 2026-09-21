# Companion: Checks Must Distinguish Unknown — Worked Incident Walkthroughs

Dated worked-incident detail split out of the always-loaded
[`checks-must-distinguish-unknown`](../checks-must-distinguish-unknown.md)
rule to keep it under the repo's line-count budget. The normative content
(CRITICAL statement, the three-state table, the signature to look for, the
Worked Instances summary table, the two Corollaries' governing statements,
Required pattern, Reporting requirement, Self-test requirement, Forbidden
patterns, Self-check) stays in the rule; this file is the extended
walkthroughs of two of the six worked instances and the full 2026-08-25
diagnostic-failure narrative, loaded on demand.

## [#1019](https://github.com/JohnGavin/llm/issues/1019) — full walkthrough

The clearest of the six: identical command, two environments.

```
$ gh pr list -R … --head worktree-agent-…        →  HTTP 401: Bad credentials
$ env -u GH_TOKEN gh pr list -R … --head …       →  [{"number":1006}]
```

The GC saw the first as "no merged PR exists" and retained ~5 GB of
already-merged worktrees indefinitely.

## [#1013](https://github.com/JohnGavin/llm/issues/1013) — full walkthrough

The most instructive of the six: `grep -c '^export' ~/.config/secrets.env #
expect 13` returns `0` for a healthy file **and** `0` for an empty one. Its
output does not vary with the thing it measures. That is not a weak check;
it is not a check.

## Worked failure, 2026-08-25 — full diagnostic narrative

By the author of this rule, about an hour after merging it. `bws` reported
`Doesn't contain a decryption key`. That was read as *"the stored token is
malformed"* and written up as "the token needs re-issuing". The token was
fine. It had never reached `bws` — the value was passed via an environment
variable that does not propagate to child processes in that session, so
`bws` received nothing and complained about the nothing.

One command settles it, and it was run only afterwards:

```bash
BWS_ACCESS_TOKEN="$VALUE" bash -c 'test -n "${BWS_ACCESS_TOKEN:-}"'   # exit 1 → never arrived
```

Cost when skipped: a confident wrong diagnosis, remediation advice for a
non-problem (re-issue a working credential), and — because the advice
carried a `<placeholder>` — a literal `<cachix-token>` string written into
the secrets vault as if it were a token. This is the origin of the
"Corollary: a placeholder in a runnable command is a defect" section in the
parent rule — `bws secret create` accepted `<cachix-token>` and returned
success, because the command was valid and only the value was wrong.


## Sections Moved from the Rule Body (2026-09-21 line-limit pass)

Original verbatim text moved out of the rule; the normative summary stays in the rule.

[#1019](https://github.com/JohnGavin/llm/issues/1019) is the clearest (identical command, two environments — one authenticated, one 401'd and silently read as "no merged PR exists", retaining ~5GB of already-merged worktrees) and [#1013](https://github.com/JohnGavin/llm/issues/1013) is the most instructive (`grep -c '^export' ~/.config/secrets.env # expect 13` returns `0` for a healthy file **and** `0` for an empty one — not a weak check, not a check). Full walkthroughs: companion doc.

| Before writing this | Establish this |
|---|---|
| "the credential is invalid" | the credential reached the tool |
| "the file is empty" | you opened the file you think you opened |
| "the branch has no merged PR" | the API call authenticated |
| "the hook never fires" | the hook is instrumented to report firing |
| "no rows matched" | the query ran against the intended database |

The same collapse — indeterminate read as negative — happens at human/session
scale, not just inside a script. "We don't have X" is a claim that a search
was run and came back empty, not a fact about the world. When the claim is
wrong, it doesn't just cost one session: every later session inherits it as
established context and re-asserts it without re-checking, so the false
negative compounds for as long as nobody happens to search the one place
that was missed.

Worked case, mycare project (2026-09-18/19): issue #008 said a CT findings
report was "missing" and escalated it as blocking a clinical decision after
five months open. The report had been sitting on disk the whole time, in a
dated subfolder nobody had checked — the project's own CLAUDE.md already
carried this exact lesson from an earlier incident ("A search of only csv/
and DuckDB missed 17 PDFs... Always check pdf/ for unprocessed downloads"),
and it still recurred, in the *same* pipeline-stage-omission shape, because
"missing" had already calcified into an accepted fact nobody re-tested.

Before treating "we don't have X" as true enough to act on (re-request it,
re-derive it, escalate it, or build a workaround for its absence): name every
location it could plausibly already exist, and actually search each one —
not just the location the original claim checked. A "missing" claim that has
survived multiple sessions unchallenged is *more* suspect, not less — its
apparent stability is nobody re-verifying it, not evidence it was ever
confirmed.

Splitting "unknown" out of "no" is only the first cut. A missing **tool** and an
absent **subject** are different failures, and collapsing them back together
re-creates the bug one level up: the reader learns the check didn't answer, but
not whether that is their problem to fix or the environment's.

Ask, every time: **could this question have been answered without the thing that
is missing?**

- **No** → genuinely INDETERMINATE. The check could not observe its subject.
- **Yes** → still a determinate result. Report it as PASS or FAIL, not unknown.

Worked example (`check_targets_presence.sh`, llm#539/#1140). Two states both
involve `Rscript` being unavailable, and they must NOT return the same code:

Verified directly: run outside the nix shell against an empty directory and it
returns **1**, not 3 — the missing interpreter does not launder a determinate
negative into an unknown.

Getting this wrong is expensive in the honest direction as well as the
dishonest one. Over-reporting INDETERMINATE trains the reader to ignore it —
and an indeterminate count nobody reads is worth exactly as much as the silent
pass this rule exists to abolish (see "Too loud is also broken" in
`verification-before-completion`).

So a check with an unavailable dependency must ask what that dependency was
actually needed **for**, and degrade only the specific sub-questions that
depended on it. Blanket "tool missing → everything unknown" is a lazy
generalisation, not caution.

Applies to any check in any project: a linter without its binary, a DB probe
without a driver, a network check without connectivity. Some of what each was
asked still has a determinate answer.

Exit-code convention for new checks (simple, 3-state form — see
`exit-code-conventions` for the full 4-state form used by any script that
ALSO needs to distinguish a usage error from "could not run"):

| code | meaning |
|---|---|
| `0` | ran; clear |
| `1` | ran; found something |
| `2` | **could not run** — do not interpret as either |

```
checks=42 clear=38 findings=2 indeterminate=2      # good
checks=42 clear=40 findings=2                      # hides the failure mode
```

```bash
# the tool is absent
GH=/nonexistent/gh    run_check   # must NOT print PASS
# the credential is invalid
GH_TOKEN=invalid      run_check   # must NOT print PASS
```
