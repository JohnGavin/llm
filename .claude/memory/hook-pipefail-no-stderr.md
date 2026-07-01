---
name: hook-pipefail-no-stderr
description: "SessionStart hook \"Failed with non-blocking status code: No stderr output\" = unguarded grep command-sub under set -euo pipefail"
metadata: 
  node_type: memory
  type: project
  originSessionId: 4edf2ca8-4c7c-43d8-8eca-73de94efd730
---

A hook error of the form `SessionStart:startup hook error — Failed with non-blocking
status code: No stderr output` almost always means the hook script runs under
`set -euo pipefail` and a **bare command-substitution assignment** whose pipeline
ends in a `grep` that found no match. The grep exits 1 → pipefail makes the pipeline
exit 1 → as a standalone assignment under `set -e` the whole script aborts with exit 1
and prints nothing to stderr (hence "No stderr output").

Diagnosis recipe: run the hook manually feeding it the JSON payload —
`echo '{"hook_event_name":"SessionStart","source":"startup","cwd":"'"$PWD"'"}' | bash <hook>; echo $?`
— then `bash -x` it; the trace stops on the line that aborts. Look for
`var=$(... | grep ... | head -1)` NOT wrapped in `if ... grep -q ...; then`.

Fix: append `|| true` to that assignment (matches how sibling guarded blocks handle it).

Real instance: `.claude/hooks/session_init.sh:847` (`n_skills=$(... grep -oE '[0-9]+ skills' ...)`),
triggered whenever `~/.claude/logs/session_init_phase4_cache.txt` is empty. Fixed in
llm#695 (2026-06-29). Canonical `.claude/hooks/` edits are blocked by `file_protection.sh`
— must go via worktree + PR, so dispatch a fixer agent, never Edit directly.

Distinct from [[startup-cost-is-mcp-not-hook]] (that's slow startup = MCP nix eval, not a hook crash).
