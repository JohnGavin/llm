---
name: delegation-under-pressure
description: Under time pressure and iterative fix cycles, opus does single-file edits directly instead of delegating to sonnet/haiku — violating auto-delegation rule and burning budget
type: feedback
---

Under iterative bug-fix cycles (e.g. email script: tibble scalar, Date coercion, filename mismatch, model equal-split — 6 commits in one session), opus did all edits directly instead of delegating to sonnet (fixer) or haiku (quick-fix).

**Why:** Each fix felt "just one more line" and the feedback loop was fast (push → CI fail → read error → fix). Delegating to a subagent adds ~30s overhead per round-trip, which felt slow when iterating. But 6 opus edits × ~$5 each = ~$30 vs 6 sonnet edits × ~$0.50 = ~$3.

**How to apply:** When entering an iterative fix cycle (CI fail → fix → push → CI fail), after the FIRST fix, delegate subsequent fixes to `fixer` (sonnet) or `quick-fix` (haiku) with the error message and file path. The 30s overhead is worth the 10x cost savings. The trigger is: "I just pushed a fix and CI failed again on the same file" → delegate.
