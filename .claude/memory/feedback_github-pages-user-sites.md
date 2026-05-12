---
name: feedback_github-pages-user-sites
description: username.github.io repos MUST serve from default branch — gh-pages branch doesn't work for user sites
type: feedback
---

GitHub Pages for `username.github.io` repos (user/org sites) MUST serve from the **default branch** (`master` or `main`), not from a `gh-pages` branch. The `gh-pages` approach only works for project repos (e.g. `username.github.io/projectname`).

**Why:** GitHub Pages treats `username.github.io` repos specially — the API accepts `gh-pages` as a source and reports `status: built`, but the site returns 404. The build succeeds silently but the content is never served. This is a documentation gap in GitHub's API — the constraint is only enforced at serving time, not at configuration time.

**How to apply:** When deploying a Quarto (or any static) site to a `username.github.io` repo:

1. Set `output-dir: docs` in `_quarto.yml`
2. Run `quarto render` (NOT `quarto publish gh-pages`)
3. Commit `docs/` to the default branch (remove `docs/` from `.gitignore`)
4. Set Pages source to `master /docs` (or `main /docs`)
5. Push to default branch
6. Add `.nojekyll` inside `docs/` to prevent Jekyll processing

For project repos (e.g. `JohnGavin/micromort`), `quarto publish gh-pages` works fine.

**The mistake (2026-04-12):** Used `quarto publish gh-pages` for the `JohnGavin.github.io` user site. API reported success, build reported `status: built`, but the site was 404. Wasted time debugging before realising the user-site constraint. Fixed by committing `docs/` to `master` and switching Pages source to `master /docs`.

**See:** `website-index-update` rule, `ci-workflows-github-actions` skill.
