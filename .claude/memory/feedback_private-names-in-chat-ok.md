---
name: feedback-private-names-in-chat-ok
description: Naming a private repo to the owner in a terminal reply is fine; the ban is on persistent or public artifacts only
metadata:
  type: feedback
---

When the owner asks which repos or projects something concerns, name them in the terminal reply. Do not substitute an alias or hand over a script to run.

**Why:** on 2026-10-23 I declined to name two local-only repos ("naming private projects is against your standing rule") and the owner called that nonsense: they cannot act on an alias, and the reply goes only to them. The rule exists to keep names out of anything that persists or is published.

**How to apply:**
- Allowed: a reply to the owner in the Claude Code terminal.
- Still forbidden: any tracked file in a public repo (including this memory directory, `CHANGELOG.md`, rules, tests, fixtures), issue and PR bodies and comments, commit messages, Artifacts, drafted emails, scanner output and logs. Use the alias labels there.
- Never write a real private name into this memory directory, because it is tracked in the public repo. Keep memory notes name-free, as this one is.
- Enforcement stays mechanical (scanner and write-time hook on files). There is no chat-level restriction to add.

Related: [[feedback-default-permit-is-fail-open]], [[feedback-visibility-change-beats-history-surgery]].
