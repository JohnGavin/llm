---
name: stale-pty-spare-cpu
description: Orphaned Claude Code spare PTY-host daemons from an old version can busy-loop at 100% CPU for days after a harness upgrade — detect by version mismatch and kill
metadata: 
  node_type: memory
  type: reference
  originSessionId: 795fc0df-186f-44dc-b042-e97d0a67d842
---

Symptom: one or more processes pegged at ~100% CPU for days, command like
`/Users/<u>/.local/share/claude/versions/<OLD_VER> --bg-pty-host /tmp/cc-daemon-*/spare/*.pty.sock ... --bg-spare ...`, with PPID 1 (orphaned/reparented to init).

Cause: Claude Code's harness pre-spawns "spare" background PTY-host daemons to
speed up launching background shells. On a harness **version upgrade** (e.g.
2.1.168 → 2.1.186) the OLD version's spares can be orphaned instead of reaped,
and a wedged spare busy-loops at 100% indefinitely. NOT caused by Bash
background jobs (those exit cleanly) and NOT a user-config issue — it's a
harness bug (orphaned-spare-after-upgrade). Observed 2026-06-23: two 2.1.168
spares stuck at 100% for 16 days while the live session ran 2.1.186.

Detect + kill stale spares (any spare whose version != the currently-running `claude`):
```bash
cur=$(readlink ~/.local/bin/claude 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'); pgrep -fl "bg-pty-host" | grep -v "${cur:-NOPE}" | awk '{print $1}' | xargs -r kill
```
Or simpler triage: `ps -Ao pid,etime,command -r | grep bg-pty-host` — kill any with multi-day ELAPSED. Graceful `kill` (TERM) suffices; the live session (`~/.local/bin/claude`, current version) is independent and unaffected. The current-version spares are idle and must be LEFT alone.
