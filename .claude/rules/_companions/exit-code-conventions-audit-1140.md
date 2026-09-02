# Companion: Exit-Code Conventions — Full Audit (JohnGavin/llm#1140)

Full per-script exit-code audit split out of the always-loaded
[`exit-code-conventions`](../exit-code-conventions.md) rule to keep it
lean. The rule states the normative 0/1/2/3 mapping and the required
pattern; this file is the evidence — every checker under `.claude/scripts/**`
and `bin/**` at the time of [JohnGavin/llm#1140](https://github.com/JohnGavin/llm/issues/1140),
with its observed exit codes and, where actually read in context, a
conformance verdict.

## How this table was built

`grep -ohE 'exit [0-9]+'` over every `.sh` file in both directories,
collapsed to the distinct literal codes per file. This catches every
literal `exit N` call but NOT dynamic exits (`exit $?`, `exit $rc`) — those
scripts show whatever literal codes they also happen to use, if any, and are
noted as "no non-zero exit observed by this grep" when they have none.

**"Conforms?" honesty note:** only the ~22 scripts listed with a verdict
other than `not reviewed` were actually opened and read in context this
pass. The other ~163 are classified purely from the code-set they use — a
script showing `binary (0/1)` genuinely cannot have codes 2/3 swapped
because it doesn't use them, but that is NOT the same claim as "this script
correctly has no indeterminate state" — per the issue's own instruction,
"cannot be indeterminate" is a claim worth checking, not one settled by a
grep. Treat every `not reviewed` row as an open question, not a clean bill
of health.

## Summary

- **185 scripts** audited (161 under `.claude/scripts/`, 24 under `bin/`)
- **7 flagged as DRIFT** — a documented or inferable exit code that
  contradicts the standard (usually: exit 2 used for INDETERMINATE, or exit
  3 used for a more-severe FAIL, inverting the pair the same way
  `check_targets_presence.sh` had before this PR)
- **6 confirmed CONFORMS / MOSTLY CONFORMS** — including the two reference
  examples named in the issue (`bin/roborev_merge_gate.sh`,
  `.claude/scripts/roborev_autoclose.sh`) plus a third found during this
  audit (`venv_supply_chain_audit.sh`)
- **163 not individually reviewed** — auto-classified by code-set only

## Fixed in this PR

`check_targets_presence.sh` — see the rule and the script's own header
comment for the before/after mapping and the falsified selftest.

## Confirmed conformant (reference examples)

- `bin/roborev_merge_gate.sh` — 1=BLOCK, 2=usage error, 3=INDETERMINATE
- `.claude/scripts/roborev_autoclose.sh` — 0=success/no-op, 1=FAIL, 3=INDETERMINATE
- `.claude/scripts/venv_supply_chain_audit.sh` — 0=pass, 1=FAIL findings, 2=usage error, 3=INDETERMINATE findings

## Drift found (follow-up, not fixed in this PR)

| Script | Drift |
|---|---|
| `agentsview_quality_baseline.sh` | Own header: exit 2 = INDETERMINATE. Should be exit 3. |
| `check_rule_scoping.sh` | Own header: exit 3 = a more-severe FAIL (check-B/C safety violations), not INDETERMINATE. |
| `roborev_weekly_chain.sh` | Exit codes name WHICH sub-step failed (1=handoff, 2=autoclose) rather than PASS/FAIL/usage/indeterminate; exit 3 is a recursion-depth guard, which `unified_duckdb_compact.sh`'s identical guard instead puts at exit 2. |
| `agent-post-verify.sh` | "No captured baseline" is bucketed with usage errors at exit 2; it reads more like INDETERMINATE (cannot verify drift without a baseline). |
| `check_internal_links.sh` | Own comment: "2 = usage/environment error" — conflates two different things under one code. |
| `signal_attachment_ingest.sh` | Own comment: "2 = usage or missing hard dependency" — same conflation. |
| `roborev_auto_close.sh` | Own comment: "2 = hard error (DB unavailable, bad arguments)" — same conflation. |

`rule_scoping_precommit.sh` is coupled to `check_rule_scoping.sh`'s mapping
and will need a comment update in the same follow-up once that script is
remapped. `.claude/scripts/roborev_merge_gate.sh` (distinct from
`bin/roborev_merge_gate.sh`) is the pre-enforcement, dry-run-only
predecessor — out of scope, not a live gate.

## Full table

| Script | Codes seen | Conforms? | Note |
|---|---|---|---|
| `agent_events_staging_import.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `agent_runs_reaper.sh` | 0 | not reviewed | no non-zero exit observed by this grep (may rely on implicit/dynamic status) |
| `agent-post-verify.sh` | 0,1,2 | DRIFT (moderate) | 1=drift detected (FAIL, correct). All other non-zero cases (-h/--help, not-a-git-repo, no captured state file, state-file repo mismatch) are bucketed at 2. 'No captured state at $STATE_FILE' is arguably INDETERMINATE (cannot verify drift without a baseline — the caller may have invoked this correctly and simply not captured one yet), not a usage error. Follow-up: move that one case to exit 3. |
| `agents_md_audit.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `agentsview_quality_baseline.sh` | 0,2 | DRIFT | Own header documents 0=PASS, 1=reserved/unused, 2=INDETERMINATE (missing binaries, unreadable DB, no bucket matched). Under the new standard this should be exit 3, freeing 2 for a genuine usage-error path. Follow-up: remap 2 to 3. |
| `audit_scheduled_workflows.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `audit_skills_if_changed.sh` | 0 | not reviewed | no non-zero exit observed by this grep (may rely on implicit/dynamic status) |
| `backfill_agent_runs_1045.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `backfill_agent_runs_270.sh` | 1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `backfill_ended_at_803.sh` | 1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `braindump_act.sh` | 1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `braindump_respond.sh` | 1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `braindump_review.sh` | 1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `branch_gc.sh` | 0 | not reviewed | no non-zero exit observed by this grep (may rely on implicit/dynamic status) |
| `branch_harvest_audit.sh` | 0,2,3 | NEEDS REVIEW | Codes 0/2/3 present: an internal summary uses `[ fail -eq 0 ] && exit 0 || exit 3` (a FAIL routed to 3, not 1 — unusual) and a separate `cd $repo` failure returns 2. Not fully read this pass; flagged rather than guessed. |
| `branch-cherry-check.sh` | 0,1,2 | CONFORMS | 2 for early argument validation (usage error, correct), 1 for actual findings (FAIL, correct). No indeterminate state in use; not verified whether one is needed. |
| `burn_rate_check_codexbar.sh` | 0 | not reviewed | no non-zero exit observed by this grep (may rely on implicit/dynamic status) |
| `burn_rate_check.sh` | 0 | not reviewed | no non-zero exit observed by this grep (may rely on implicit/dynamic status) |
| `bws_launcher.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `bws_set_secret.sh` | 2 | LOW PRIORITY / BORDERLINE SCOPE | Single exit 2 = usage/placeholder-input refusal (the checks-must-distinguish-unknown rule cites this script's placeholder-refusal behaviour approvingly). Mostly an action script (sets one secret) rather than a repeatable check; only one non-zero code is defined, so no drift is possible yet. |
| `canonical_projects_audit.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `canonical_projects_migrate.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `capability_registry_regen_cron.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `capture_braindump.sh` | (none) | not reviewed | no non-zero exit observed by this grep (may rely on implicit/dynamic status) |
| `cc-worktree.sh` | 0,1,2,3,4,5 | OUT OF SCOPE | Action/creation script, not a check — codes 0-5 each name a distinct creation-failure reason (branch exists, project not found, worktree path exists, ...). Reference example of a script correctly outside this rule's scope; named as such in exit-code-conventions.md. |
| `cc.sh` | 0,2 | OUT OF SCOPE | Launcher wrapper (selects permission mode, execs claude). Not a check. |
| `check_146_panel_data_watcher.sh` | 0,2 | NEEDS REVIEW | Codes 0/2 present, not read in context this pass. |
| `check_cross_repo_symlinks.sh` | 0,1,2 | LIKELY CONFORMS | 2 for -h/usage and a selftest-summary path; 1 for findings via selftest assertions. Not fully read this pass. |
| `check_dark_contrast.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `check_dashboard_color_scheme.sh` | 2 | NEEDS REVIEW | Only a single literal `exit 2` (usage message for a missing required argument) was found — no explicit PASS/FAIL exit call located by this pass's grep, so normal completion likely falls through to the last command's implicit status. Worth confirming that is intentional. |
| `check_grep_portability.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `check_indeterminate_handling.sh` | 0,1,2 | not reviewed | uses code 2, no 3 — verify 2 means usage error, not indeterminate |
| `check_internal_links.sh` | 0,1,2 | DRIFT (moderate) | Own comment: '2 = usage/environment error' — conflates two different things under one code. Follow-up: split into 2 (usage) and 3 (environment error, e.g. network/tool unavailable). |
| `check_qmd_fence_parity.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `check_roborev_agent_privacy.sh` | 0,2 | not reviewed | uses code 2, no 3 — verify 2 means usage error, not indeterminate |
| `check_rule_scoping.sh` | 0,1,2,3 | DRIFT | Own header documents 0=clean, 1=check-A only (context bloat), 2=rules dir not found/usage error, 3=check-B/C failures (a MORE SEVERE FAIL, not an unknown). Exit 3 here means 'safety violation', colliding with the standard's INDETERMINATE. Follow-up: fold check-B/C into exit 1 (FAIL) with severity in the message, reserve 3 for a genuine indeterminate case (e.g. rules dir exists but unreadable due to permissions). |
| `check_skill_frontmatter.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `check_skill_security.sh` | 0,1,2 | not reviewed | uses code 2, no 3 — verify 2 means usage error, not indeterminate |
| `check_targets_presence.sh` | 0,1,2,3 | FIXED (this PR) | Was 2=undeclared-absence/3=usage-error (swapped). Now 0=PASS, 1=FAIL (parse-error or undeclared-absence, distinguished by message), 2=usage error, 3=INDETERMINATE (Rscript missing). Selftest asserts all four codes explicitly and falsifies each. |
| `check_tcc_prompt_durability.sh` | 0,1,2 | not reviewed | uses code 2, no 3 — verify 2 means usage error, not indeterminate |
| `check_tlang_flake_closure_rebuild.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `chrome_tab_backup.sh` | 0 | not reviewed | no non-zero exit observed by this grep (may rely on implicit/dynamic status) |
| `chrome_tab_restore.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `clean-stale-worktrees.sh` | 1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `cleanup_ephemeral_repos.sh` | 1,2 | not reviewed | uses code 2, no 3 — verify 2 means usage error, not indeterminate |
| `codex_show_overnight_learning.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `codex_with_fallback.sh` | 0,127 | not reviewed | non-standard code set: 0,127 |
| `codex-start.sh` | (none) | not reviewed | no non-zero exit observed by this grep (may rely on implicit/dynamic status) |
| `command_usage_staging_import.sh` | 0 | not reviewed | no non-zero exit observed by this grep (may rely on implicit/dynamic status) |
| `credential_hygiene_check.sh` | 0,1,2 | not reviewed | uses code 2, no 3 — verify 2 means usage error, not indeterminate |
| `credential_single_source_check.sh` | 0,1,2 | not reviewed | uses code 2, no 3 — verify 2 means usage error, not indeterminate |
| `credential_tier_lookup.sh` | 0,1,2 | not reviewed | uses code 2, no 3 — verify 2 means usage error, not indeterminate |
| `cron_catchup.sh` | 0 | not reviewed | no non-zero exit observed by this grep (may rely on implicit/dynamic status) |
| `cron_deploy_pull.sh` | (none) | not reviewed | no non-zero exit observed by this grep (may rely on implicit/dynamic status) |
| `cross_modal_eval.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `data_quality_incidents_seed_apply.sh` | 1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `detect_patterns.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `entity_propagate.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `error_events_staging_import.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `etl_freshness_check.sh` | 0,1,2 | not reviewed | uses code 2, no 3 — verify 2 means usage error, not indeterminate |
| `etl_freshness_upsert.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `hook_event_emit.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `hook_events_load.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `housekeeping_schema_apply.sh` | 1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `incident_response.sh` | 1,2 | not reviewed | uses code 2, no 3 — verify 2 means usage error, not indeterminate |
| `indeterminate_hook_install.sh` | 1,2 | not reviewed | uses code 2, no 3 — verify 2 means usage error, not indeterminate |
| `indeterminate_precommit.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `install_markitdown.sh` | 0,1,2 | not reviewed | uses code 2, no 3 — verify 2 means usage error, not indeterminate |
| `install_roborev_primary_shim.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `kb_digest_builder.sh` | 0,1,2 | not reviewed | uses code 2, no 3 — verify 2 means usage error, not indeterminate |
| `kb_digest_send.sh` | 0,1,2 | not reviewed | uses code 2, no 3 — verify 2 means usage error, not indeterminate |
| `lib_signal_process_guard.sh` | (none) | not reviewed | no non-zero exit observed by this grep (may rely on implicit/dynamic status) |
| `log_session.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `markitdown_convert.sh` | 0,1,2 | not reviewed | uses code 2, no 3 — verify 2 means usage error, not indeterminate |
| `mem_pr.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `model_mix_log.sh` | 1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `nix_gcroot_refresh.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `phi_scan.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `pr_status_pulse.sh` | 0 | not reviewed | no non-zero exit observed by this grep (may rely on implicit/dynamic status) |
| `private_data_git_hooks_install.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `private_data_history_audit.sh` | 0,1,2 | not reviewed | uses code 2, no 3 — verify 2 means usage error, not indeterminate |
| `private_data_scan.sh` | 0,1,2 | not reviewed | uses code 2, no 3 — verify 2 means usage error, not indeterminate |
| `private_values_sync.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `process_pending_skillify.sh` | 0 | not reviewed | no non-zero exit observed by this grep (may rely on implicit/dynamic status) |
| `qa_gate_check.sh` | 0 | not reviewed | no non-zero exit observed by this grep (may rely on implicit/dynamic status) |
| `qa_vignette_tabs.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `quarto_post_render_contrast.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `quarto_post_render_links.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `r_btw_codex_mcp.sh` | 1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `r_btw_mcp_launch.sh` | (none) | not reviewed | no non-zero exit observed by this grep (may rely on implicit/dynamic status) |
| `r_code_check.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `record_prediction.sh` | 1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `render_signal_launchd_plists.sh` | 0,1,2 | not reviewed | uses code 2, no 3 — verify 2 means usage error, not indeterminate |
| `repo_visibility.sh` | 0,1,2 | not reviewed | uses code 2, no 3 — verify 2 means usage error, not indeterminate |
| `roborev_ack.sh` | 0,1,2 | not reviewed | uses code 2, no 3 — verify 2 means usage error, not indeterminate |
| `roborev_agent_health.sh` | 0,1,55,124 | not reviewed | non-standard code set: 0,1,55,124 |
| `roborev_auto_close.sh` | 0,1,2 | DRIFT (moderate) | Own comment: '2 = hard error (DB unavailable, bad arguments)'. DB unavailable is INDETERMINATE; bad arguments is usage error. Follow-up: split into 2 and 3. |
| `roborev_auto_refine.sh` | 0,1,78 | not reviewed | non-standard code set: 0,1,78 |
| `roborev_auto_verify.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `roborev_autoclose.sh` | 0,1,3 | CONFORMS | 0=success/no-op, 1=FAIL (guard rejected / hard error), 3=INDETERMINATE. No code 2 in use (fine — not every script needs a distinct usage-error path). |
| `roborev_bridge_to_unified.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `roborev_citation_validate.sh` | 0,2 | not reviewed | uses code 2, no 3 — verify 2 means usage error, not indeterminate |
| `roborev_commit_msg_validator.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `roborev_commit_reference_rate_check.sh` | 0,1,2 | not reviewed | uses code 2, no 3 — verify 2 means usage error, not indeterminate |
| `roborev_consistency_check.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `roborev_daemon_launcher.sh` | 78 | not reviewed | non-standard code set: 78 |
| `roborev_daily_backlog_aggregator.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `roborev_eval_run.sh` | 0,1,2 | not reviewed | uses code 2, no 3 — verify 2 means usage error, not indeterminate |
| `roborev_handoff.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `roborev_install_auto_verify_hook.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `roborev_install_post_merge_hook.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `roborev_job_reaper.sh` | (none) | not reviewed | no non-zero exit observed by this grep (may rely on implicit/dynamic status) |
| `roborev_merge_gate.sh` | 0,1,2 | LEGACY / OUT OF SCOPE | .claude/scripts/roborev_merge_gate.sh is the pre-enforcement predecessor to bin/roborev_merge_gate.sh -- documented elsewhere as dry-run only (always exits 0), kept only for week-1 signal logging. Its exit-2 usage-error path is unaffected by this issue since it never reaches a FAIL/INDETERMINATE distinction in practice. Not a live gate. |
| `roborev_metrics_etl.sh` | 0,1,2 | not reviewed | uses code 2, no 3 — verify 2 means usage error, not indeterminate |
| `roborev_migrate_component5.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `roborev_poll_merges.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `roborev_primary_shim.sh` | 0,1,127 | not reviewed | non-standard code set: 0,1,127 |
| `roborev_project_backlog.sh` | 0,1,2 | not reviewed | uses code 2, no 3 — verify 2 means usage error, not indeterminate |
| `roborev_requeue_dropped.sh` | 0,1,2 | not reviewed | uses code 2, no 3 — verify 2 means usage error, not indeterminate |
| `roborev_retention.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `roborev_review.sh` | 1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `roborev_severity_autoclose.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `roborev_summary_wrap.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `roborev_verify_closure.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `roborev_weekly_chain.sh` | 1,2,3 | DRIFT | 1=handoff sub-step failed, 2=autoclose sub-step failed, 3=depth-guard/recursion-protection triggered. None of these map cleanly onto PASS/FAIL/usage/indeterminate — this orchestrator uses exit codes to say WHICH stage failed, not the standard meanings. Follow-up: move the recursion guard to 2 (usage/environment misconfiguration, matching unified_duckdb_compact.sh's convention for the identical guard) and consider carrying which-stage-failed in the log line instead of a third code. |
| `roborev_weekly_update.sh` | 0,1,2 | not reviewed | uses code 2, no 3 — verify 2 means usage error, not indeterminate |
| `rotate_gmail_password.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `rotate_secret.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `rule_scoping_precommit.sh` | 0,1,3 | COUPLED TO check_rule_scoping.sh | Wrapper that maps check_rule_scoping.sh's 0/1/3 down to its own binary 0=allow/1=block for the git hook. Its own two codes are fine (git hooks are inherently binary) but its comments name the checker's exit 3 as the block trigger — once check_rule_scoping.sh is remapped (see above), this wrapper's mapping comment needs a matching update in the same follow-up. |
| `secret_exposure_scan.sh` | 0,1,2 | not reviewed | uses code 2, no 3 — verify 2 means usage error, not indeterminate |
| `secrets_cache_drift.sh` | 0,1,2 | not reviewed | uses code 2, no 3 — verify 2 means usage error, not indeterminate |
| `secrets_cache_regen.sh` | 0,1,2 | not reviewed | uses code 2, no 3 — verify 2 means usage error, not indeterminate |
| `secrets_to_bws.sh` | 0,1,2 | not reviewed | uses code 2, no 3 — verify 2 means usage error, not indeterminate |
| `self_review_stage1.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `self_review_verify.sh` | 0 | not reviewed | no non-zero exit observed by this grep (may rely on implicit/dynamic status) |
| `sentinel_log_sweep.sh` | 64 | not reviewed | non-standard code set: 64 |
| `session_end_refine.sh` | 0 | not reviewed | no non-zero exit observed by this grep (may rely on implicit/dynamic status) |
| `session_events_staging_import.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `session_index_dedup.sh` | 0,1,2 | not reviewed | uses code 2, no 3 — verify 2 means usage error, not indeterminate |
| `session_reaper.sh` | 0 | not reviewed | no non-zero exit observed by this grep (may rely on implicit/dynamic status) |
| `session_slug.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `setup_ast_grep_r.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `signal_attachment_ingest.sh` | 0,2 | DRIFT (moderate) | Own comment: '2 = usage or missing hard dependency'. Missing hard dependency is INDETERMINATE (cannot run at all), not a usage error. Follow-up: split. |
| `signal_braindump_handler.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `signal_notes_sync.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `skill_usage_etl.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `skill_usage_staging_import.sh` | 0 | not reviewed | no non-zero exit observed by this grep (may rely on implicit/dynamic status) |
| `skill_usage_tracker.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `skillify_backlog.sh` | 1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `staleness_banner.sh` | 0 | not reviewed | no non-zero exit observed by this grep (may rely on implicit/dynamic status) |
| `staleness_collect.sh` | 1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `staleness_schema_apply.sh` | 1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `unified_duckdb_backup.sh` | 0,1,2 | not reviewed | uses code 2, no 3 — verify 2 means usage error, not indeterminate |
| `unified_duckdb_compact.sh` | 0,1,2,3 | MOSTLY CONFORMS | 0=selftest pass, 1=selftest fail, 2=recursion-depth guard (usage/environment misconfiguration — correctly not 3). No content-check indeterminate state currently exists; follow-up: consider exit 3 if the duckdb binary is missing or the DB is locked, rather than an uncoded shell error. |
| `venv_supply_chain_audit.sh` | 0,1,2,3 | CONFORMS | 0=pass (implied), 1=FAIL findings, 2=usage error (bad flag/path), 3=INDETERMINATE findings. Second reference example alongside check_targets_presence.sh and bin/roborev_merge_gate.sh. |
| `verify_no_launchd_secret_leak.sh` | 0,1,2 | not reviewed | uses code 2, no 3 — verify 2 means usage error, not indeterminate |
| `vignette_check.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `wait_for_resolvable_host.sh` | 0,64 | not reviewed | non-standard code set: 0,64 |
| `wiki_health_check.sh` | 0,1,2 | not reviewed | uses code 2, no 3 — verify 2 means usage error, not indeterminate |
| `worktree_gc.sh` | 0,1,401 | not reviewed | non-standard code set: 0,1,401 |
| `check_skill_sizes.sh` | (none) | not reviewed | no non-zero exit observed by this grep (may rely on implicit/dynamic status) |
| `config_digest_cron.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `generate_vignette_logos.sh` | 0 | not reviewed | no non-zero exit observed by this grep (may rely on implicit/dynamic status) |
| `kb_digest_daily_cron.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `launchd_health_audit.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `launchd_health_weekly_cron.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `launchd_run_record_install.sh` | (none) | not reviewed | no non-zero exit observed by this grep (may rely on implicit/dynamic status) |
| `launchd_run_record.sh` | 1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `overnight_self_review_email_cron.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `publish_roborev_data.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `refresh_and_preserve.sh` | 0 | not reviewed | no non-zero exit observed by this grep (may rely on implicit/dynamic status) |
| `refresh_codexbar_and_commit.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `roborev_daily_cron.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `roborev_install_all_hooks_all_repos.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `roborev_install_all_hooks.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `roborev_install_commit_msg_hook_all.sh` | 1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `roborev_install_commit_msg_hook.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `roborev_install_post_commit_verifier_all.sh` | 1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `roborev_install_post_commit_verifier.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `roborev_install_post_merge_hook_all.sh` | 1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `roborev_install_post_merge_hook.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `roborev_merge_gate.sh (bin/)` | 0,1,2,3 | CONFORMS | Reference example named in the issue: 1=BLOCK, 2=usage error, 3=INDETERMINATE. No change needed. |
| `roborev_weekly_rollup_cron.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `stage1_findings_daily_cron.sh` | 0,1 | not reviewed | binary (0/1) — no usage-error or indeterminate code in use |
| `uninstall_ccusage_automation.sh` | (none) | not reviewed | no non-zero exit observed by this grep (may rely on implicit/dynamic status) |
