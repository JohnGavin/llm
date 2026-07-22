---
name: roborev-automated-data-noise
description: "Bot-authored data-commit repos (llmtelemetry) flood roborev with noise findings; fix via exclude_patterns; don't confuse crashed jobs / range reviews with findings"
metadata: 
  node_type: memory
  type: reference
  originSessionId: a9909498-52d4-4aca-b0ce-0cad7159228a
---

llmtelemetry gets ~400 commits/week, ~100% bot-authored (`data: update telemetry data` → `inst/extdata/**`; `chore: Auto-refresh ccusage cache`). roborev reviewed every one → 234 findings/7d (104 High) at a 16.7% close rate, dwarfing every other repo (next was 8). A code-review agent pointed at regenerated data flags spurious churn.

**Fix (2026-07-22):** per-repo `.roborev.toml` with `exclude_patterns = ["inst/extdata/**", "vignettes/data/**", "CHANGELOG.md", ".claude/CURRENT_WORK.md"]` — a data-only commit then presents an empty diff → no findings; real `R/`/`scripts/` commits still reviewed. Commit the toml with `[skip review]` in the message. See the [[roborev-exclude-patterns]] rule (now covers TWO categories: session-ledger files + automated-data commits).

**Two gotchas when bulk-closing (`roborev close <id>`):**
1. Reviews that "fail to close" are usually `verdict=null status=failed` — **crashed** jobs (the persistent gemini outage). `roborev close` cannot address them (no verdict to resolve); they're agent-health noise, not findings, and clear via re-run/purge, not close.
2. `job_type=range` reviews span a commit RANGE (`git_ref=SHA..SHA`), NOT a single commit. Inspect `git log A..B` before closing — llmtelemetry's 180 range reviews turned out to be mostly REAL code (fixes/features from an earlier dev period), not data-noise. **Never mass-close range reviews by assumption.** Only single `data:`-subject commit reviews were safe to close.
