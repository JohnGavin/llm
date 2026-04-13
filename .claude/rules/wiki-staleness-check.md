# Rule: Wiki Staleness Check After Major Sessions

## When This Applies

At session end (`/session-end` or `/bye`) when the session made significant changes:
- >10 files changed, OR
- >3 vignettes touched, OR
- CI/deployment workflows modified, OR
- Core architecture changed (simulation engine, async patterns, etc.)

## CRITICAL: Wikis Become Silently Stale

GitHub wikis are not part of the codebase and are not updated by CI.
After a major refactor, wiki pages referencing old patterns (function names,
architecture, performance numbers, deployment steps) become misleading.

## Required Action

At session end, if the project has a GitHub wiki:

1. Count changed files: `git diff --name-only HEAD~N | wc -l`
2. If threshold exceeded, warn:
   ```
   ⚠️  N files changed — review wiki for staleness
      Wiki: https://github.com/OWNER/REPO/wiki
   ```
3. List wiki pages that likely reference changed content (grep for
   function names, file paths, architecture terms from the diff)

## No-Op for Projects Without Wikis

Most projects don't have wikis. The check should silently skip when:
- `gh api repos/OWNER/REPO/pages` returns no wiki, OR
- The repo has no wiki tab enabled

## What Makes a Wiki Page Stale

| Signal | Example |
|--------|---------|
| References a deleted/renamed function | Wiki says `run_simulation()` but it was replaced |
| Quotes performance numbers | Wiki says "~53 seconds" but vectorization made it 10x faster |
| Describes old architecture | Wiki says "per-walker R loop" but now uses matrix ops |
| References old CI steps | Wiki says "build-webr required" but it's now optional |
| Documents old UI | Wiki describes "Walker Paths tab" but it was removed |

## Implementation

Phase 1 (current): Manual review at session end — agent warns if many files changed.
Phase 2 (future): Automated scanning via `session_stop.sh` hook.
Phase 3 (future): Auto-create issues for stale wiki pages.

See JohnGavin/randomwalk#199 for the implementation plan.

## Related Rules

- `wiki-storage-policy` — central hub vs per-project wiki decisions
- `verification-before-completion` — don't claim completion without checking
