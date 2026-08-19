---
name: health-check-inherits-a-different-path
description: "A health check run from an interactive shell resolves binaries from YOUR PATH, not the daemon's — so it passes on tools the daemon cannot see, and the resulting outage looks like broken logic rather than a missing directory"
metadata:
  node_type: memory
  type: feedback
---

When a supervised process (launchd, systemd, cron) resolves executables from
`PATH`, a health check you run by hand proves nothing about what that process
can reach. Your shell's `PATH` is not its `PATH`. The check passes, the service
fails, and the gap between them is invisible from either side.

**Why:** launchd jobs get the `PATH` written in their plist — typically a short
list that omits `~/.local/bin`, `~/bin`, and anything a dotfile prepends. An
interactive shell has all of those. `which <tool>` therefore answers a different
question than the daemon is asking.

**How to apply:** resolve from the supervised process's own environment, never
your shell's:

```bash
# what the daemon can actually see
ps eww -p <pid> | tr ' ' '\n' | grep -m1 '^PATH='
env -i PATH="<that exact PATH>" /usr/bin/which toolA toolB toolC
```

Do this when adding any new external tool a daemon must invoke, and when a
service reports "not available" for something you can run yourself. Treat a
hand-run health check as evidence about *your* environment only.

**Worked case (2026-08-18, llm#746).** roborev's configured review fallback
`gemini → claude-code` never engaged. `roborev check-agents` reported
`claude-code OK`. The daemon reported:

```
no review agent available: no configured agent available
(preferred: "claude-code", backups: claude-code)
```

Its launchd `PATH` lacked `~/.local/bin`, where `claude` lives; `codex` and
`gemini` were both on the daemon's `PATH`, so only the fallback was affected.
Under `env -i` with the daemon's exact `PATH`, `which claude` exited 1. The
waterfall was configured correctly the whole time and had nowhere to fall.
Every gemini quota failure became a dead job instead of a fallback.

The plist comment recorded the cause without anyone noticing: *"Same PATH as
com.roborev.auto-refine.plist — the daemon resolves `gemini`/`codex` … Copied
deliberately, not re-derived."* A third agent was added to the config later; the
`PATH` it needed was never revisited.

**Two related traps this sits next to:**

- A *reload* is not enough. `bootout` + `bootstrap` is required to pick up an
  edited plist — stopping the service leaves launchd holding the old file in
  memory, and `KeepAlive` restarts it with the stale config within seconds. See
  [[launchd-bootout-is-not-a-disable]].
- Verify by outcome, not by enqueue. `Enqueued job N (agent: claude-code)`
  proves the binary resolved; only `status=done` proves it ran.

Same family as [[probe-must-not-share-writer-path]] — a check that shares the
wrong context measures itself rather than its target — and
[[feedback_verify-causal-claims]], since "the fallback logic is broken" was the
plausible story and a missing directory was the fact.
