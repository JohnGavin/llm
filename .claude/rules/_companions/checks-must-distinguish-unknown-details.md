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
