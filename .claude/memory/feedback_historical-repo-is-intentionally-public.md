---
name: feedback-historical-repo-is-intentionally-public
description: "historical (financial/quant research repo) is deliberately public; the public-private-boundary \"money\" trigger does not apply to it"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 1e8da749-a620-49f1-83e5-58d69cb2020b
  modified: 2026-09-22T10:07:32.862Z
---

The `historical` project (`~/docs_gh/proj/finance/data/historical`,
`github.com/JohnGavin/historical`, public) is **intentionally public by
policy** — all of its content should be public-only, nothing specifically
private. Its subject matter is quant/market research and methodology, not
personal financial data (contrast with `premortem`, which holds real
estate/expense figures and is correctly private).

**Why:** [[public-private-repo-boundary]]'s "money" trigger is a
default-to-private heuristic for content touching the owner's own finances.
It does not apply here — the user confirmed 2026-09-22 that `historical`'s
public status is deliberate, not an oversight to flag.

**How to apply:** Do not re-raise `historical`'s public visibility as a
boundary concern. If a *specific* file or figure inside `historical` looks
like personal financial data (as opposed to market/research data), that is
still worth flagging on its own merits — the repo-level exemption doesn't
cover a genuine leak of personal data into it.
