---
name: hook-cwd-deletion
description: "Hook error 'ENOENT posix_spawn /bin/sh' means the session's working directory was deleted — restart from a stable checkout, it is not a missing-shell or hook bug"
metadata: 
  node_type: memory
  type: reference
  originSessionId: 795fc0df-186f-44dc-b042-e97d0a67d842
---

Symptom: every Claude Code hook fails with `Error occurred while executing hook command: ENOENT: no such file or directory, posix_spawn '/bin/sh'` (non-blocking, fires repeatedly).

Diagnosis: `/bin/sh` exists and the hooks are fine. `posix_spawn` of an existing absolute binary returns `ENOENT` when **the spawning process's current working directory has been deleted** — the kernel can't resolve the cwd to start the child, and the error is attributed to the program name. So the session's cwd was removed out from under it (a `/tmp` staging dir that got cleaned, a torn-down worktree, or a `rm -rf` of an ancestor of cwd).

Recovery: end the session and relaunch from a stable checkout — `cd ~/docs_gh/<project>` then start via `cc.sh`. In-session `cd` is unreliable because the shell itself can't spawn from a dead cwd. Prevention: don't run sessions from `/tmp`/ephemeral worktrees; never force-remove the cwd or an ancestor — run `rm` with absolute paths from a stable cwd. Tracked in llm#647; observed in llmtelemetry 2026-06-18.
