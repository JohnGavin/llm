# Swallow-pattern sweep — JohnGavin/llm#1067 (2026-09-21)

Scope: `.claude/hooks/`, `.claude/scripts/`, `bin/` (`*.sh`).
Pattern: a command followed by `|| echo`, `|| true`, or `|| :` such that "the
tool is missing / failed" and "the tool ran and found nothing" share an exit
and, worse, share an output.

Prior work: [#1217](https://github.com/JohnGavin/llm/pull/1217) (commit
`5c1adf52`) swept the same pattern and fixed `canonical_projects_audit.sh` and
`audit_skills_if_changed.sh`, and added the pre-deletion consumer check
(`pruned_script_consumer_check.sh`). This sweep is a second, independent pass
with a different method and found three more.

## Method (and its limits)

1. Raw grep `\|\|\s*(echo|true|:)` over `*.sh`: **983 hits**. Far too noisy to
   classify individually (most are `|| true` on `rm`, `mkdir`, `git config`,
   `kill`, cleanup and best-effort telemetry).
2. Narrowed to lines that INVOKE a script or interpreter (`bash x`, `"$VAR"`,
   `~/...`, `Rscript`) and then swallow: **58 candidates**, all read below.
3. Cross-check with `check_indeterminate_handling.sh --all`: 57 findings
   (`swallowed-status`, `swallowed-status-fn`, `pipefail-abort`). These are a
   *different* defect family (empty substitution result vs error). They are
   NOT triaged here; see Follow-ups.

Limit: step 2's regex requires the swallow on the same physical line as the
invocation. A multi-line invocation with `|| true` on a continuation line is
missed. Treat this as a strong sample, not a proof of completeness.

## Classification of the 58 candidates

A "check" here means: its result (output or status) is consumed to decide or
report something.

Counts per category were not tallied; the 58 lines were read and sorted into
these buckets. Only the DEFECT count (3) is exact.

| Verdict | Meaning / examples |
|---|---|
| DEFECT (fixed): 3 | consumed check, missing/failed is indistinguishable from clean |
| Best-effort telemetry/emit | `hook_event_emit.sh`, `log_agent_run.sh`, staging imports, `nix_gcroot_refresh.sh` callers; result never consumed; by design fail-open |
| Action, not a check | `roborev close/comment/refine`, `launchctl unload`, `git notes add`, `duckdb` ledger writes |
| Selftest / fixture / self-recursion | `bash "$0"`, selftest helpers, heredoc fixtures |
| Passive logger, not a check | `entity_propagate.sh`, `drift_check.py`, `mem_pr.sh`, `model_mix_log.sh` |
| False positive (`echo` inside a `$(...)` label) | `check_skill_security.sh:180`, `branch_harvest_audit.sh:310` |

## Findings that matter

| # | file:line | command | check? | verdict |
|---|---|---|---|---|
| 1 | `.claude/scripts/roborev_handoff.sh:901` | `gh issue view ... .body \|\| echo ""` | Yes: the idempotency check for the weekly digest | **DEFECT, fixed.** A failed read became an empty body, which read as "job not in digest", after which `gh issue edit --body-file` **overwrote the entire digest** with only the new block. Destructive, not merely silent. Now: rc captured; on failure logs `INDETERMINATE`, digest not edited, job left open (retried next run). |
| 2 | `.claude/hooks/session_init.sh:811` | `[ -x burn_rate_check.sh ]` guard with no `else` | Yes: burn-rate banner | **DEFECT, fixed.** Missing script printed nothing, identical to a healthy run that emits no banner. Now prints `INDETERMINATE — check DID NOT RUN` to stderr. (The existing `\|\| echo "Burn rate: check failed"` for a present-but-failing tool was already distinct.) |
| 3 | `.claude/hooks/session_stop.sh:57` | `[ -x audit_skills_if_changed.sh ]` guard with no `else` | Yes: skill audit at /bye | **DEFECT, fixed.** Same shape as #2. The very script `#1217` repaired internally could itself be silently absent from its caller. |
| 4 | `.claude/hooks/session_init.sh:1030` | `phase_roborev_autoclose 2>/dev/null \|\| echo "roborev-autoclose: threshold=unknown ..."` | Yes | OK. Failure already prints a distinct `unknown` line. |
| 5 | `.claude/hooks/session_init.sh:511` | `[ -n "$result" ] && echo ... \|\| echo "R-universe: parse error"` | Yes | OK. Distinct message. |
| 6 | `.claude/scripts/etl_freshness_check.sh:567` | `rm -f ... \|\| true` | No | Selftest cleanup. |
| 7 | `.claude/scripts/check_indeterminate_handling.sh:288` | `gh pr view ... \|\| echo ""` | No | Heredoc fixture for the linter's own selftest, intentionally the bad shape. |

## Pattern with many instances that were deliberately NOT changed

`[ -x "$SCRIPT" ] && "$SCRIPT" ... || true` best-effort chains in
`session_stop.sh` (lines 63, 304, 312, 367) and the ETL/cron scripts. The
called tools are passive loggers/ETL steps whose output is discarded, so a
missing tool loses telemetry rather than mis-reporting a verdict. That is a
lower-severity variant (a silent gap in the ledger, which the unified DB's
freshness checks already surface). Changing them all would add stderr noise
to every `/bye`. Flagged, not fixed.

## Follow-ups (not done here)

1. **`roborev_handoff.sh:~891` digest lookup** (`gh issue list ... || echo ""`)
   has the same conflation: a failed lookup reads as "no digest this week" and
   creates a **duplicate** digest issue. Lower severity than #1 (no data loss),
   same fix shape. Left because it changes create-vs-skip control flow and
   deserves its own test.
2. **The 57 `check_indeterminate_handling.sh --all` findings** are a separate
   family and need their own triage; several (`roborev_merge_gate.sh`
   `_get_pr_commits` etc.) sit on a merge-gate path and are worth prioritising.
3. **Multi-line invocations** are outside this sweep's regex (see Limit).
4. **`verify_mermaid_dashboard.sh`: restore or not?** NOT decided here. Flagged
   for the user. `#1217` recorded from the issue thread that the runtime-mounted
   mermaid pattern is still in live use downstream, which argues for restoring
   or replacing the check. The tombstone in `mermaid-dashboard-pattern.md`
   now names the removal commit `ab14383f`.
5. Wiring `pruned_script_consumer_install.sh` into the live pre-commit hook is
   still a deliberate human step (per `#1217`).

## Verification

* `bash -n` clean on all three edited scripts.
* Each fix demonstrated against the shipped code with the tool absent
  (`INDETERMINATE` printed) and present (clean output, no `INDETERMINATE`).
* Falsified: the pre-change code from `git show HEAD:` is silent when the tool
  is absent, and the pre-change `roborev_handoff` read yields an empty body and
  proceeds to overwrite.
* `.claude/tests/test_session_stop_index_gating.sh`: 6 passed, 0 failed.
* No existing test covers `roborev_handoff.sh`; its fix was demonstrated by
  extracting the shipped snippet, not by a committed regression test.
