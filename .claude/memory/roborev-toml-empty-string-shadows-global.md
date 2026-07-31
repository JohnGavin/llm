---
name: roborev-toml-empty-string-shadows-global
description: "A per-repo .roborev.toml key set to '' OVERRIDES the global config.toml value to empty; only an ABSENT key inherits the global default"
metadata: 
  node_type: memory
  type: reference
  originSessionId: 9dae2337-e5c2-4baf-88ef-76baf4b26095
---

roborev config resolution: a key present in a repo's `.roborev.toml` with an
**empty string** (`refine_backup_agent = ''`) does NOT inherit the global
`~/.roborev/config.toml` default — it **overrides it to empty**. Only a key that
is entirely **absent** from `.roborev.toml` falls through to the global value.

Verified 2026-07-31 (#723): global `config.toml` set `refine_backup_agent='claude-code'`,
but `roborev config get refine_backup_agent` returned empty from inside the llm repo
(whose `.roborev.toml` had `refine_backup_agent = ''`) and returned `claude-code` from
`/tmp` (no `.roborev.toml`). `default_backup_agent` (absent from the repo toml) correctly
inherited the global.

Consequence: to un-shadow a broken global default per-repo you MUST set the explicit
value in `.roborev.toml` — deleting the value to `''` is NOT enough (it keeps the
shadow). This is why the #723 fix pinned `refine_backup_agent`/`fix_backup_agent` to
`'claude-code'` explicitly rather than relying on the global config.toml patch.

The daemon reads the **main checkout's** `.roborev.toml` (`~/docs_gh/llm/.roborev.toml`),
not a worktree's — so a per-repo fix is only live after the PR merges + main is pulled +
`roborev daemon restart`. The global config.toml patch is live immediately (all
non-shadowing repos) after a daemon restart. See [[roborev-gemini-dead-silent-failure]]
and [[roborev-automated-data-noise]].
