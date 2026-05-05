---
gitignore: true
note: This file is GITIGNORED and must NEVER be committed. Add SECRETS.md to .gitignore before copying this template.
---

# SECRETS — Credential Inventory for [project-name]

This file is the per-project token registry. It is gitignored. Update it whenever
a token is created, rotated, or revoked. The "Scope (actual)" column is the
load-bearing one — populate it by checking the provider's token management UI, not
by guessing from the variable name.

## How to Populate

Find actual scopes at the provider:

| Provider | Where to check scope |
|---|---|
| GitHub PAT (classic) | https://github.com/settings/tokens → click token name |
| GitHub fine-grained PAT | https://github.com/settings/personal-access-tokens → view permissions |
| Railway | https://railway.app/account/tokens → inspect token details |
| AWS IAM | AWS Console → IAM → Users → Security credentials → Policies attached |
| Binance | https://www.binance.com/en/my/settings/api-management → permissions column |
| Clockify | https://app.clockify.me/user/settings → API → token description |
| Cachix | https://app.cachix.org/personal-auth-tokens |
| Cloudflare | https://dash.cloudflare.com/profile/api-tokens → view token summary |

## Token Inventory

| Token name | Stored at | Scope (intended) | Scope (actual at provider) | Created | Last rotated | Owner |
|---|---|---|---|---|---|---|
| `GH_TOKEN` | `~/.Renviron` | Read repos + trigger CI | repo:full, workflow, write:packages, delete:packages — includes branch deletion | 2025-01-10 | — | john.b.gavin@gmail.com |
| `RAILWAY_API_TOKEN` | `~/.Renviron` | Deploy staging env only | Full account access: create/delete services, volumes, and environments | 2025-11-03 | — | john.b.gavin@gmail.com |
| `BINANCE_API_KEY` | `~/.Renviron` + `blogs/.Renviron` | Read market data | Spot trading enabled; no withdrawal (verify in API management UI) | 2024-06-15 | 2025-06-15 | john.b.gavin@gmail.com |

> Note on the rows above: `GH_TOKEN` and `RAILWAY_API_TOKEN` illustrate the
> critical divergence — the intended scope was narrow but the actual scope is
> broader. This gap is where incidents happen (see PocketOS/Railway 2026-04-25).

## Review Schedule

- Re-audit scopes every **6 months** (add calendar reminder when this file is updated).
- Rotate tokens after any **staff or contractor change**.
- Rotate immediately if a token appears in a log, error message, or unexpected context.
- After rotation: update the "Last rotated" column here before committing the
  rotated-token change to `.Renviron`.
- Annual review: delete tokens unused for >12 months; revoke at provider first,
  then remove from this file.
