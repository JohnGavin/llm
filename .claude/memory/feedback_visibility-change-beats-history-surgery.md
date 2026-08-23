---
name: feedback_visibility-change-beats-history-surgery
description: "To contain data exposed in a repo, change repo visibility before rewriting history — it is more complete, reversible, and cheaper"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: f2ceb4a5-18a9-47e4-95c0-1bb159694960
  modified: 2026-08-22T21:45:28.579Z
---

When personal data is found in a git repo, **evaluate making the repo private
before rewriting history.** Visibility change is usually the better instrument,
and the instinct to reach for `git-filter-repo` is often wrong.

**Why:** both were done on 2026-08-22, hours apart, and the comparison is stark.

| | history rewrite (`llm`) | visibility change (`llmtelemetry`) |
|---|---|---|
| Scope reached | branches + tags only | **everything** — history, PR refs, Pages |
| Left exposed | **438 PR refs**, unfixable without GitHub Support | none |
| Reversible | no — force-push, all SHAs changed | **yes**, one command |
| Collateral | 74 worktrees stale, 3 PRs orphaned, every clone broken | none |
| Effort | mirror clone, filter-repo, force-push, re-sync, backup | one command |

`refs/pull/*` is the decisive asymmetry: GitHub owns those refs, a force-push
cannot touch them, and they carry full reachable history — so 8 rewritten
commits remained fetchable from **438** PR refs. A rewrite cannot reach them;
making the repo private removes them from public reach immediately.

**How to apply:**

1. Ask first: **does this repo need to be public at all?** Check `forkCount` and
   `stargazerCount` — a repo with zero of both has no audience to break, and
   privatising costs nothing.
2. Prefer visibility change when the repo has no external users. Prefer a
   rewrite only when the repo *must* stay public.
3. If rewriting anyway: take a mirror backup first, push `refs/heads/*` and
   `refs/tags/*` explicitly (a `--mirror` push is **rejected** — it tries to
   push read-only `refs/pull/*` and hangs), and expect PR refs to survive.
4. Never present a rewrite as closure. It stops casual discovery and stops the
   value spreading into new clones. It does not un-publish anything — and if
   the exposed value cannot be rotated (a primary phone number, a home
   address), the exposure is permanent regardless.

Related: [[feedback_default-permit-is-fail-open]], [[deploy-gap-stale-main-checkout]].
Origin: llm#946, 2026-08-22.
