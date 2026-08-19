---
name: exec-zsh-does-not-clear-env
description: "Removing a variable from a dotfile does not unset it in a running shell; `exec zsh` inherits the environment and will not clear it"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: f2ceb4a5-18a9-47e4-95c0-1bb159694960
  modified: 2026-08-13T18:23:49.118Z
---

Deleting `export FOO=…` from `~/.config/secrets.env` (or any rc file) removes it
for **future** shells only. A shell already running keeps the exported value,
and **`exec zsh` does NOT clear it** — `exec` replaces the process image but the
environment is inherited, so rc files are re-read while every already-exported
variable survives.

Observed 2026-08-13: `GH_TOKEN` and `GITHUB_PAT` were deleted from
`secrets.env`, verified absent from `.zshrc`, `.zshenv`, `positron/`,
`~/.claude/env/`, and absent from the launchd gui domain
(`launchctl getenv` → empty). After `exec zsh` they were **still set**, so
`gh auth login` kept using the revoked `GH_TOKEN` and refused to store its own
credential:

> The value of the GH_TOKEN environment variable is being used for
> authentication. To have GitHub CLI store credentials instead, first clear
> the value from the environment.

**Why:** ancestry. The value was inherited from the shell that launched the
process tree. It persists in every descendant — including a Claude Code
session's Bash tool — until a shell is started that is NOT descended from the
tainted one.

**How to apply:**

- To clear in the current shell: `unset FOO BAR`. `exec zsh` is not enough.
- For one command, regardless of ancestry: `env -u FOO -u BAR <command>`.
  This is the reliable form and works even inside an already-tainted session.
- A brand-new terminal window/tab started from the launcher (not a child of
  the tainted shell) is clean.
- **Diagnostic order** when a variable "won't go away": check the files, then
  `launchctl getenv NAME` (gui domain), then conclude process-tree
  inheritance. Do not assert "it's gone" from file evidence alone — verify
  with `env | cut -d= -f1 | grep -E '^NAME$'` in the shell that matters.
- Never print the value while diagnosing. Test set/unset with
  `printenv NAME >/dev/null` or the name-only `env | cut -d= -f1` form.

Applies to any exported variable, not just credentials — but it matters most
for credentials, because the stale value is usually a revoked one that makes
tools fail in a way that looks like a different problem.

Related: [[deploy-gap-stale-main-checkout]] (same shape: the fix landed but the
running thing still had the old state), [[feedback_verify-causal-claims]].
