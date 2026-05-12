---
name: ci-strategy
description: GitHub Actions CI optimization strategy — what runs where, minute conservation, R-universe delegation
type: project
---

# GitHub Actions CI Strategy

## Budget: 2,000 min/month (resets April 1)

**2026-03-23 optimization:** reduced from ~13,300 to ~4,600 min/month projected.

## Key Principle: R-universe First

R-universe (johngavin.r-universe.dev) builds, checks, and hosts binaries for free on their infrastructure. **Never duplicate R-CMD-check or R-universe-test in GitHub Actions.**

Session-start hook (Phase 6) checks R-universe build status automatically.

## What Runs Where

| Task | Where | Cost |
|------|-------|------|
| R CMD check | R-universe | Free |
| Package binary builds | R-universe | Free |
| pkgdown sites | Build locally, push docs/ | Free |
| Data pipelines (scheduled) | GitHub Actions | Quota |
| Dashboard deploys | GitHub Actions | Quota |
| Cachix seeding | GitHub Actions (weekly) | Minimal |

## Per-Repo Workflow Inventory (2026-03-23)

| Repo | Workflows | Triggers |
|------|-----------|----------|
| **micromort** | leaderboard-refresh (weekly), pkgdown (paths: docs/) | Cron + paths |
| **irishbuoys** | data-update (daily), deploy-dashboard (paths: docs/), storm-alert, data-freshness, api-drift, seed-cachix | Cron + paths |
| **footbet** | (none — R-universe handles everything) | — |
| **solwatch** | CI (paths-ignore docs), deploy-dashboard (push+workflow_run), batch-convert, health-check, portfolio-refresh | Paths + cron |
| **coMMpass** | 01-env, 02-data, 03-analysis, 04-website (release+paths), 05-check (paths), 06-push-cachix | Release + paths |

## Deleted Workflows (2026-03-23)

| Repo | Deleted | Saved | Reason |
|------|---------|-------|--------|
| micromort, irishbuoys, footbet | R-CMD-check.yml | ~1,200 min/2wk | R-universe does this free |
| micromort, irishbuoys, coMMpass | r-universe-test.yml | ~1,200 min/2wk | Redundant — R-universe auto-builds |
| footbet | pkgdown.yml | ~500 min/2wk | Build locally, push gh-pages |

## Optimization Rules

- **Every push trigger MUST have `paths:` filter** — no unconditional CI on push
- **Deploy workflows trigger on release or paths only** — not every push
- **All nix workflows use Cachix** — pull pre-built binaries, don't rebuild
- **macOS/Windows CI forbidden for private repos** — 10x/2x multiplier
- **pkgdown builds locally** — never in CI (bslib breaks in Nix anyway)
- **Test coverage local only** — `covr::package_coverage()` + `covr::report()`
