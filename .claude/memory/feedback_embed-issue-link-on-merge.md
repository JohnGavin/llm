---
name: feedback-embed-issue-link-on-merge
description: When merging/reporting a PR or issue, always embed a clickable link, never a bare number
metadata:
  type: feedback
---

When reporting a merge, a PR action, or referencing an issue to be merged/closed,
ALWAYS include an embedded markdown link (e.g. `[#750](https://github.com/JohnGavin/llm/pull/750)`)
rather than a bare `#750`. Applies to all projects, all future work — PR/merge
summaries, session-end notes, CHANGELOG-adjacent prose reported to the user.

**Why:** a bare number forces the user to hunt for the URL; an embedded link is
one click. The user asked for this explicitly on 2026-07-08 right after merging #750.

**How to apply:** in any user-facing report that names a PR/issue as the subject
of an action (merge, close, open), render it as a clickable link to the exact
GitHub URL. Codified in the `pr-shipping-discipline` rule (llm#751).
