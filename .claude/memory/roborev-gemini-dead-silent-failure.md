---
name: roborev-gemini-dead-silent-failure
description: roborev reviews silently fail because gemini free-tier is dead; health checks read the wrong metric
metadata: 
  node_type: memory
  type: project
  originSessionId: e535c923-1a3c-4ece-b1de-4022c883237f
---

**roborev "0 failed / ok" can be a LIE.** The `summary --json` has two sections:
`overview` (job outcomes: queued/running/done/**failed**) and `verdicts`
(reviews that produced a pass/fail). The `/bye` check and `roborev_agent_health.sh`
read `verdicts.failed` (or codex-only counts), which stay 0 when reviews **crash
before producing a verdict** — masking total failure. Always check
`overview.failed` and `failures.errors.{crash,quota}` and the per-`agents[].errors`.

**Root cause observed 2026-06-25:** Google killed free-tier `gemini-cli`
(`IneligibleTierError: This client is no longer supported ... UNSUPPORTED_CLIENT`,
exit 55). 28/28 reviews that day ran gemini and crashed. Compounding faults:
1. gemini permanently dead; codex rate-limited until mid-July.
2. The live daemon (running since Jun 19, after an agent-health swap) had **stale
   config** still using `gemini`, even though `config.toml` said
   `default_agent='claude-code'`. Daemon must be restarted to reload config.
3. `roborev_agent_health.sh` only counts **codex** failures and "remediates" by
   **swapping to gemini** (line ~191/204) — routes to the dead agent and is blind
   to its 100% crash rate, so it logs "ok, failures=0".

**Immediate fix applied:** edited `~/.roborev/config.toml` (home file) — all
`*_backup_agent = 'gemini'` → `'codex'`; `default_agent` already `claude-code`
(verified WORKS via `roborev review --agent claude-code`). Then
`roborev daemon restart`. Verified: next review ran claude-code, status=done.
Backups: `~/.roborev/config.toml.bak-gemini-dead-*`.

**Still TODO (repo-protected, needs PR):** rewrite `roborev_agent_health.sh` to
monitor the ACTIVE agent and never route to gemini; fix the `/bye` roborev check
and `session_init.sh` banner to read `overview.failed`/crashes not
`verdicts.failed`; project `.roborev.toml` `backup_agent='gemini'` → `'codex'`.
See [[startup-cost-is-mcp-not-hook]] for the sibling "verify the metric, don't
trust the summary" lesson.

**Recurrence 2026-07-07 — different root cause, same silent-failure surface.**
All reviews failed with `codex quota exceeded` even for jobs assigned to
gemini/claude-code, and the daemon **ignored `--agent`**. Root cause: the
per-reasoning **model pin** `review_model_thorough=gemini-2.5-flash-lite` (from
#733) is applied to WHATEVER agent runs — so when gemini quota-fails and it
falls back, the backup agent is handed a gemini model it can't use
(`404 model_not_found` for claude-code; codex separately quota-dead) and the
whole job aborts. `default_backup_agent` had also reloaded to `codex` on daemon
restart. **Escape hatch that WORKS:**
`roborev review <sha> --local --agent claude-code --model sonnet` — bypasses the
daemon AND overrides the poisoned model pin, producing a real verdict on
claude-sonnet-5 (this is how #744/#747 got reviewed). Also set
`default_backup_agent=claude-code` via `config set --global`. Proper fix
(per-agent model pinning, so a single-provider outage can't take down all
reviews) tracked in #746.
