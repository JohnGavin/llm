---
name: reference_github-actions-storage-billing
description: "How to diagnose a GitHub \"Actions storage 100%\" alert — the billing usage API, what counts, and the setup-r-dependencies cache-per-dependency-release trap"
metadata:
  node_type: memory
  type: reference
  originSessionId: 13c7d939-24e5-42f3-876c-c659b8212a8f
  modified: 2026-10-20T17:33:06.850Z
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
is settable, so workflows cannot be made to share a key. **CORRECTION 2026-10-16: `cache: false`
(llmtelemetry#370, merged 2026-09-20) was NOT neutral.** The step took ~55 s on hit days
(2026-09-07..20) and 35-58 min on every run since 2026-09-21 (26 of 26); the one miss day
(2026-09-10) took 55 min. The earlier "48-61 s on miss days" compared hit days only. Cost: ~52 min
per run, 1,560 min in Oct 1-16, so the account hit 90% of 2,000 free minutes. Correlation with the
merge date is exact; the cause is not yet confirmed by a hit-vs-miss experiment (llmtelemetry#393).
**2026-10-20 "100% of 0.5 GB storage" alert, measured:** October storage GB-hours by repo: irishbuoys 1,077 (about 3x the whole 360 allowance), llmtelemetry 372, crypto_swarms 27, everything else under 1. `grossAmount == discountAmount` and `netAmount` 0 for every repo, so it is a quota banner, not a charge (the repos are public). irishbuoys held 10.9 GB in 6,807 caches: 8.08 GB of `DeterminateSystems/magic-nix-cache-action` entries (6,806 tiny `.narinfo`/`.nar.zstd` keys; used by data-update, api-drift, seed-cachix), 2.69 GB of per-run `targets-<run_id>` caches (5 x ~540 MB), plus two 568 MB `pipeline-failure` artifacts with no `retention-days`. Failed runs had stopped: none in irishbuoys after 2026-10-10, none in llmtelemetry after 2026-10-11, so the emails were the storage banner, not failures. The local clone is `~/docs_gh/proj/data/weather/irish_buoy_network/irishbuoys` (`cc-worktree.sh irishbuoys` does not resolve it). Fix PR in irishbuoys removes magic-nix-cache and bounds the failure artifact; the `targets-` cache policy is a separate decision. `gh search code` returned [] for a string that exists, so scan workflow files directly.
**Billing facts (verified 2026-10-16):** the minutes quota counts PRIVATE repos only; public repos
show raw minutes with a 100% discount (net $0). `usageItems[].quantity` for `Actions Linux` is raw
minutes; reconstructing per-job `ceil(minutes)` from `actions/runs/<id>/jobs` matched the billing
API exactly (1728 and 94). Linux $0.006/min, macOS 3-core $0.062/min. Per-workflow breakdown is NOT
in the billing API; build it from the runs/jobs API. The composite action hides its inner steps, so
time the combined step `Run r-lib/actions/setup-r-dependencies@v2`.
