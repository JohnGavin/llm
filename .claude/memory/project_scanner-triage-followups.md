---
name: project-scanner-triage-followups
description: "Dated follow-ups for the scanner triage rollout (llm#1458) and privacy layers; the owner expects the agent to raise these unprompted"
metadata:
  node_type: memory
  type: project
  originSessionId: 13c7d939-24e5-42f3-876c-c659b8212a8f
  modified: 2026-10-17T13:30:02.443Z
---

Owner instruction 2026-10-17: "you track all of this" (scanner triage rollout) and "do all of these" (term-sync launchd job, selftest, uncovered scanners).

State on 2026-10-17: `com.claude.private-terms-sync` (03:05 daily) and `com.claude.scanner-triage` (04:10 daily, DRY-RUN wrapper) are registered in launchd (plists copied to ~/Library/LaunchAgents). Neither had run yet. The standing authorisation for the chmod/auto-file classes is in AGENTS.md (llm#1463). `--apply` is OFF until the owner edits `bin/launchd-recorders/scanner-triage`.

**RAISE FIRST, unprompted:**
- **Sun 2026-10-18 (morning):** confirm the 03:05 term-sync ran (header `generated=` date, count only), the 03:40 secret scan has ~0 new rows after the detector fixes (#1460), the 04:10 triage wrote `~/.claude/logs/scanner_triage/2026-10-18.json`, and the first weekly history audit (03:15 Sun) reads "ok, 0 new". Report each as PASS / FAIL / INDETERMINATE.
- **About Thu 2026-10-22:** after ~4 days of clean dry-run output, ask the owner whether to switch `--apply` on. Never switch it on myself.
- **Before 2026-10-23:** the private-term list goes stale at 7 days; the sync job above should keep it fresh. Check the header date.

**Why:** the owner does not want to keep opening issues for what the daily email flags; the email must only say "action required" for findings that need them.

**Known gaps to report until fixed:**
- term-sync source b (local-only project folders) contributes 0 terms: "extra-dirs file missing". Local-only projects are therefore not protected by the term list.
- `phi_scan.sh` prints the matched PHI value in its output, is not scheduled, and uses `mapfile` (breaks on macOS bash 3.2).
- L3 CI check (#1389) needs the owner to set secrets PRIVATE_TERMS_SALT and PRIVATE_TERM_HASHES; `private_term_hash_scan.sh` is not wired into any workflow yet.
- Three scanners (`phi_scan`, `private_term_hash_scan`, `venv_supply_chain_audit`) are unscheduled and write nothing to housekeeping_runs, so the email cannot see them.
