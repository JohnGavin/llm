---
name: destructive-guard-blocks-rm
description: "Harness destructive-FS guard blocks rm -rf on home paths even with user confirmation — stop retrying, hand the user a ! command"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 4854e9d1-4cc0-4a69-8d8d-03939c73c029
---

In a worktree session the harness's destructive-FS guard **denies `rm -rf` on `~/...` paths** (e.g. `~/.cache/qmd`, `~/.npm-global`) **even after the user explicitly confirmed the deletion**. The guard sits below the permission-prompt layer and is not bypassed in worktree sessions. Both a combined multi-path `rm` and a single `rm -rf ~/.cache/qmd` were denied.

**Why:** the guard is independent of in-conversation user confirmation; retrying the same command just gets denied again (and trips `pivot-signal` after 2 tries).

**How to apply:** when an `rm`/destructive FS op on a home path is denied, STOP — do not retry variants. Hand the user the exact command to run via the in-session `! <cmd>` prefix, which executes in their own shell and bypasses the guard. Then verify with a read-only `du`/`ls` (those are allowed). Reclaimed ~2.5GB this way after the qmd spike (2026-06-27). Related: [[feedback_safe-deletion]] (the *content* check before deleting), [[npm-global-in-nix-shell]] (what created the artifacts).
