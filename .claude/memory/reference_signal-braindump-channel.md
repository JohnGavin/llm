---
name: reference-signal-braindump-channel
description: "Signal braindump capture must be scoped to the \"Notes to llm\" chat only — other chats produce off-channel noise"
metadata: 
  node_type: memory
  type: reference
  originSessionId: a3346af5-65b1-4df8-a747-936bd4171ae8
  modified: 2026-09-23T13:13:33.675Z
---

The only Signal chat intended to feed `knowledge/raw/braindumps/` and the
`braindumps` DuckDB table (`~/.claude/logs/unified.duckdb`) is the group
named **`Notes to llm`**. Any other Signal chat/group the account is in is
NOT a braindump source — messages from other chats should be ignored by
`signal_braindump_handler.sh`, not captured.

**Why this matters:** as of 2026-08-31, `signal_braindump_handler.sh`
captured messages from every Signal chat, not just this one. It already
resolves `group_name` per message but never used it to filter. ~9 photo
captures (2026-08-22 → 08-31, most deduped away before reaching the DB) with
0-1 characters of OCR text and no actionable content turned out to be noise
from a different chat. Root-cause fix tracked at
[JohnGavin/llm#1113](https://github.com/JohnGavin/llm/issues/1113).

**How to use this:** when triaging braindumps (raw files or DB rows), treat
an entry as suspect/noise if it did not plausibly come from `Notes to llm` —
check the file's own `Source:` header line where present, or the
`group_name` value once #1113's filter lands. Don't spend triage effort
trying to interpret content from an off-channel capture as if it were an
intentional note.

**#1113 only fixed HALF the pipeline — recurred 2026-09-17/21.**
`signal_braindump_handler.sh`'s group filter operates on the Signal
message JSON (where `groupInfo` lives). It has no effect on
`signal_attachment_ingest.sh`, a **separate** script that scans the flat,
per-account `~/.local/share/signal-cli/attachments/` directory — every
attachment from every Signal chat lands there with **no group/chat
metadata recoverable from the file itself**. So an image from an
off-channel chat kept being silently ingested exactly like the original
#1113 bug, just one layer further down. Two more tablet-photo images
(2026-09-17, 2026-09-21) reached `knowledge/raw/braindumps/` this way and
were archived to `raw/braindumps/_off-channel-noise/` on 2026-09-22
(commit `6b6235a` in the `knowledge` local repo) rather than triaged as
content.

Companion code fix: [JohnGavin/llm#1243](https://github.com/JohnGavin/llm/pull/1243)
(merged) — an `SIGNAL_INGEST_ALLOWLIST` file, written by
`signal_braindump_handler.sh` per run from the in-scope group's attachment
IDs, that `signal_attachment_ingest.sh` consults before ingesting anything
from its directory scan; fails closed (ingests nothing) if the allowlist
was meant to be set but the file is missing. No separate tracking issue
was filed for this — #1113 remains the root-cause issue for the whole
class of bug (both the text and attachment paths).

**Do not re-raise this as a new discovery.** If the same class of noise
(an image with no plausible connection to "Notes to llm") shows up again,
it is this same gap, not a new bug — archive it the same way, and check
whether PR #1243 is actually deployed in the running pipeline rather than
assuming the fix landed just because the code merged.
