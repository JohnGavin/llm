---
name: project-llmtelemetry-actions-followups
description: "Dated follow-ups for llmtelemetry GitHub Actions minutes/storage (Mon 2026-10-19 cache check; after 2026-11-01 back to daily + R 4.5 pin test); the user wants the AGENT to raise these, not them"
metadata:
  node_type: memory
  type: project
  originSessionId: 13c7d939-24e5-42f3-876c-c659b8212a8f
  modified: 2026-10-16T14:36:13.004Z
---

The user said the agent must remember these, not them. At the start of any llm
session on or after the date, check this file and raise the item FIRST.

1. **From Mon 2026-10-19 (after both llmtelemetry weekly runs finish):**
   `gh cache list --repo JohnGavin/llmtelemetry`. Expect one cache (~382 MiB).
   If two or more (the two workflows compute different keys), delete the OLDER
   one(s) with `gh cache delete <id>` (user authorised surplus-cache deletes on
   2026-10-16). Also report: did each run take ~52 min (cache miss)? minutes left
   (`actions_usage.sh`; ~177 left before Monday, ~73 expected after)? did a 7-day
   eviction bite? Do NOT delete the only cache.
2. **From 2026-11-01 (quota reset):** (a) return `daily-report.yaml` and
   `hf-archive.yaml` to daily crons (user-approved plan; revert #394), watch
   minutes and storage for a week; (b) run one dispatch test with R pinned to 4.5
   and no cache (~52 min worst case); if the cold install is < 5 min drop the
   cache for good, else build option B (own `actions/cache` + `gh cache delete`
   of old keys, needs `actions: write`). Detail: llmtelemetry#393.
3. Still unverified: R 4.6.1-no-binaries hypothesis; whether the $0 budget blocks
   public repos; whether weekly archive/email lose data.

**Why:** quota counts private repos only; $0 budget blocks runs at the limit;
storage could run out ~Oct 20-23.
**How to apply:** see [[reference_github-actions-storage-billing]].
