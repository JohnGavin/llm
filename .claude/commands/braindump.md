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
4. **Check it isn't already captured or already done** (see below) — BEFORE
   raising anything
5. Route each item to the right tracker (see "Where issues go")
6. Present the structured prompt, ready to paste into a Claude Code session
7. Ask: "Would you like me to execute this prompt, refine it, or save it for later?"

## CRITICAL: check for prior capture before raising anything

On 2026-09-02, a braindump pass found that **every one of the four tennis items
was already tracked** (`ISSUES.md` #31 and #32, in more detail than the notes
themselves) and the bereavement note was already
`premortem/issues/0073-farewill-bereavement-contact.md`. In the same session,
two of five GitHub issues being worked (#1075, #1035) had already been fixed
weeks earlier and never closed — each burned a full agent dispatch to
rediscover that.

So before raising, extending, or dispatching work on ANY item:

1. **Grep the destination tracker** for the item's distinctive nouns —
   `ISSUES.md`, `issues/`, `TODO.md`, or `gh issue list --search`. Braindumps
   repeat themselves: the same idea often arrives two or three times, days
   apart, as it turns over in the user's head.
2. **Grep `main` for the concrete thing the item names** — the file, symbol,
   config key, or behaviour. `git log --oneline --all -S '<symbol>'` finds the
   commit that introduced or removed a string.
3. **Check unmerged branches and worktrees** — work may be finished but not
   landed: `git log --all --oneline --grep '<keyword>'`.

Then report one of three verdicts, never two —
per [`checks-must-distinguish-unknown`](../rules/checks-must-distinguish-unknown.md):

- **ALREADY CAPTURED / DONE** — cite the file, issue number, or SHA. If it is
  done but the issue is still open, say so: it wants closing, not working.
- **NEW** — nothing found; raise it.
- **PARTIALLY CAPTURED** — the common case. An existing issue covers most of
  it; the braindump adds specifics. **Append an addendum to the existing item
  rather than opening a duplicate**, and say which details were genuinely new.

"I didn't find it" is not the same as "it isn't there" — say which greps you ran.

## Where issues go

| Destination | Mechanism |
|---|---|
| Repo with a GitHub remote (`llm`, `micromort`, …) | `gh issue create` |
| **Private / local-only repo** (no remote, or GitHub-private) | **A `.md` file in that repo**, following ITS existing convention |
| Anything containing PII or health data | **Never** a public repo — `.md` in the private repo only |

Read the target repo's existing convention before writing; do not invent one:

- `tennis` — single `ISSUES.md`, numbered `## N. Title (OPEN\|DONE, date)`
  sections, append-only, IDs never reused (it has no GitHub remote at all)
- `premortem` — `issues/NNNN-kebab-title.md`, one file per issue, plus
  `issues/INDEX.md`
- Otherwise — look for `ISSUES.md`, `TODO.md`, or an `issues/` directory and
  match what is there; only create a new convention if none exists

**Privacy routing is not optional.** `llm` and `micromort` are PUBLIC. A
braindump carrying a phone number, address, will reference, medication, or any
health detail goes to the private repo's `.md` tracker and nowhere else — see
[`public-private-repo-boundary`](../rules/public-private-repo-boundary.md). Its
four triggers (phone, home, health, money) decide this, not whether the string
"looks" sensitive.

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
