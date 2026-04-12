---
paths:
  - "DESCRIPTION"
  - "NEWS.md"
  - "_pkgdown.yml"
---
# Website Index Update on Major Version

## Rule

When a project reaches a **major version milestone** (1.0.0, 2.0.0, etc.), add it to the
johngavin.github.io website index page if not already listed.

## When This Triggers

- After bumping DESCRIPTION version to X.0.0 (major release)
- After merging a PR that constitutes a major version milestone
- During `/session-end` if version was bumped to major

## Required Action

1. Check if project is already on the index: `grep "project-name" ~/docs_gh/johngavin.github.io/index.qmd`
2. If missing, add an entry with: project name, one-line description, link to GitHub repo and pkgdown site
3. Commit the index page update to the johngavin.github.io repo

## What Constitutes a Major Milestone

- First public release (0.1.0 or 1.0.0)
- Breaking API changes warranting a major version bump
- Project graduation from experimental to stable

## Deployment: username.github.io is a Quarto site

The index site at `~/docs_gh/JohnGavin.github.io/` is a Quarto website
(migrated from Hugo 2026-04-12). To update and deploy:

```bash
# Edit index.qmd or projects.qmd
cd ~/docs_gh/JohnGavin.github.io
quarto render                    # builds to docs/
git add docs/ index.qmd          # commit rendered output
git commit -m "update index"
git push                         # Pages serves from master /docs
```

**CRITICAL: username.github.io repos MUST serve from the default branch.**
Do NOT use `quarto publish gh-pages` — that creates a gh-pages branch which
silently 404s for user sites. The API accepts it and reports `status: built`
but the content is never served. Only project repos (e.g. `user.github.io/project`)
can use the gh-pages branch.

## Checklist

- [ ] Is the version in DESCRIPTION a major milestone?
- [ ] Is the project already listed on johngavin.github.io?
- [ ] If not listed, add entry with name, description, and links
- [ ] Run `quarto render` in the johngavin.github.io repo
- [ ] Commit `docs/` + source changes to master branch
- [ ] Push to origin (Pages auto-deploys from master /docs)
