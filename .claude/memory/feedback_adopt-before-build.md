---
name: adopt-before-build
description: "Before proposing to build or estimating effort, check whether our stack's primitives or an existing tool already solve it — adopt/wire beats reimplement"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 795fc0df-186f-44dc-b042-e97d0a67d842
---

Planning a knowledge-base search layer, I framed it as "re-implement the DuckDB+RRF pattern" and estimated 2–4 days. The user pushed back ("why reimplement, that's a lot of work?") and was right twice over: (1) DuckDB already ships the primitives — `fts` (BM25) + `vss` (HNSW), with RRF being ~15 lines of SQL, so it was glue not an engine (~1 day); (2) the whole problem is already solved by an existing tool (`qmd` — local hybrid markdown search with an MCP-server variant).

**Why:** Defaulting to "build" inflates effort estimates and burns budget reimplementing solved problems. The user's instinct ("this must be solved already") was correct and mine wasn't.

**How to apply:** Before proposing to build anything or estimating effort, do two checks first: (a) does our existing stack already provide the primitive? (DuckDB `fts`/`vss`, duckplyr, targets, cli, etc. — see [[tool-preferences]]); (b) is there a maintained tool that already does this? (WebSearch + `gh` the candidate). Lead with adopt/wire; only propose building when both checks fail. Quote the existing primitive or tool in the recommendation.
