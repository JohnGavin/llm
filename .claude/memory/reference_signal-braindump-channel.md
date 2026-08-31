---
name: reference-signal-braindump-channel
description: "Signal braindump capture must be scoped to the \"Notes to llm\" chat only — other chats produce off-channel noise"
metadata: 
  node_type: memory
  type: reference
  originSessionId: a3346af5-65b1-4df8-a747-936bd4171ae8
  modified: 2026-08-31T15:54:16.681Z
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
