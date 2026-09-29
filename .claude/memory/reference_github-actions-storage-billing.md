---
name: reference_github-actions-storage-billing
description: How to diagnose a GitHub "Actions storage 100%" alert — the billing usage API, what counts, and the setup-r-dependencies cache-per-dependency-release trap
metadata:
  type: reference
---

**Diagnose with data, not the dashboard.** With a token that has the `user` scope:
`gh api "/users/JohnGavin/settings/billing/usage?year=2026&month=9"` (large JSON; aggregate with
`jq` by `.sku == "Actions storage"` and `.repositoryName`; unit is GigabyteHours). The old
`/settings/billing/actions` returns HTTP 410 and `/settings/billing/budgets` returns 404 for
personal accounts (so the budget setting must be read at github.com/settings/billing/budgets).
0.5 GB included is about 360 GB-hours per month (my calculation). `netAmount` was $0 throughout:
overage is priced at about $0.00034 per GB-hour (about $0.24 per GB-month).

**Per repo:** `gh api /repos/O/R/actions/cache/usage` and `gh cache list --repo O/R`. Artifact
sums from `/actions/artifacts` include EXPIRED artifacts (`.expired` true) that no longer count:
filter `select(.expired|not)`. The usage counter lags after `gh cache delete`.

**The trap (llmtelemetry, Sept 2026):** `r-lib/actions/setup-r-dependencies@v2` keys its cache on a
hash of a lockfile regenerated from an empty library on every run, so every dependency release
saves a new 384 MB cache; two daily workflows x three releases = 6 caches. Only `cache-version`
is settable, so workflows cannot be made to share a key. `cache: false` measured neutral
(setup 48-61 s on miss days vs 43-67 s on hit days; public RSPM binaries). Fix landed in
llmtelemetry#370; the composite action hides its inner steps, so timings are of the combined step
`Run r-lib/actions/setup-r-dependencies@v2` and its `Post Run` step (the 7-9 s post step marks a
cache write). Public repos show usage lines too but discounted; llmtelemetry alone exceeded the quota.
