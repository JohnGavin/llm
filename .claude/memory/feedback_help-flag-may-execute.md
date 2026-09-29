---
name: feedback_help-flag-may-execute
description: Never run an unread script with --help to learn its flags — a script without arg parsing just executes; read its header instead
metadata:
  type: feedback
---

`script.sh --help` is only safe if the script parses arguments. Many scripts here do not.

**Why:** 2026-09-20. To find a dry-run flag I ran `data_quality_incidents_seed_apply.sh --help`.
It has no argument handling, so it applied the seed to the live `~/.claude/logs/unified.duckdb`
(one older `llm1035` incident row, idempotent — no damage, but a write I had said I would
show a dry-run for first).

**How to apply:** learn a script's interface with `Read` (its header comment) or
`grep -nE 'getopts|--help|--dry-run|--selftest'` — never by executing it. For a DB writer, test
against a `cp` of the database under the scratchpad first, and only then run the real one on an
explicit yes. `--selftest` is only safe if the grep shows it exists.
