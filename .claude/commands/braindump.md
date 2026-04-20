---
description: Process latest brain dump into a structured Claude Code prompt
---

# Brain Dump Processor

Read the most recent brain dump from `~/docs_gh/llm/knowledge/raw/braindumps/` and organise it into a structured Claude Code prompt.

## Steps

1. Find the most recent file in `~/docs_gh/llm/knowledge/raw/braindumps/` (by modification time)
2. Read its contents
3. Organise the raw text into:
   - **Project**: which project this relates to (infer from content)
   - **Intent**: what the user wants to accomplish (1-2 sentences)
   - **Tasks**: concrete numbered steps
   - **Constraints**: any mentioned preferences, tools, or limitations
   - **Questions**: anything ambiguous that needs clarification
4. Present the structured prompt, ready to paste into a Claude Code session
5. Ask: "Would you like me to execute this prompt, refine it, or save it for later?"

## Sources

Brain dumps may arrive via:
- Signal "Notes" chat (extracted by cron to braindumps/)
- Email to self (Gmail MCP → braindumps/)
- Direct terminal input (`cat >> ~/docs_gh/llm/knowledge/raw/braindumps/$(date +%F-%H%M).md`)

## If no brain dumps found

Say: "No brain dumps found in `knowledge/raw/braindumps/`. To capture one:
- **Signal**: Open Notes chat, dictate a voice message or type
- **Terminal**: `cat >> ~/docs_gh/llm/knowledge/raw/braindumps/$(date +%F-%H%M).md` then type, Ctrl-D to save
- **Email**: Send to yourself, it'll be picked up by the Gmail integration"
