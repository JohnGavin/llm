---
name: editing-through-symlinks
description: When a config file is symlinked to a git-tracked source, use `>` redirect or the Edit tool — `mv` replaces the symlink with a regular file
type: feedback
originSessionId: 0f3eeea4-2270-4ae7-86b3-04cd5817add2
---
When a config file lives as a symlink (e.g. `~/.claude/settings.json` → `~/docs_gh/llm/.claude/settings.json` since 2026-05-05), the only safe edit forms are:

1. **Edit tool** — writes through the symlink correctly
2. **Shell `>` redirect** — `jq ... > ~/.claude/settings.json` truncates and writes through the symlink target (works because `>` opens the path that the symlink resolves to)

**Forbidden form**: `jq ... > /tmp/new.json && mv /tmp/new.json ~/.claude/settings.json`

**Why:** `mv` removes the destination first (which removes the symlink) and replaces it with a regular file copied from the source. The symlink is gone; the repo file is no longer being written to. The next git operation in the repo sees no change because the live edits went to a regular file in `~/.claude/`, not the symlinked target.

**How to apply:** Whenever the user has a symlinked config file (settings.json, dotfiles managed with stow, etc.), prefer Edit tool. If using shell, use `>` directly. If you must use `mv`, restore the symlink afterwards: `cp source target && rm source && ln -s real_target symlink_path`.

**Reason logged:** This happened mid-session 2026-05-05 (llm1) when applying `permissions.deny` patterns. The recovery cost ~3 tool calls; the lesson is cheap if remembered, expensive every time it isn't.
