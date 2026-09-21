# Companion: CI Outage -- Local Substitutes for CI-Only Gates

Origin: [JohnGavin/llm#1234](https://github.com/JohnGavin/llm/issues/1234)
(GitHub Actions monthly budget exhausted). A gate that does not run looks
identical to a gate that passed (`checks-must-distinguish-unknown`). This
companion is loaded on demand; it is not an always-loaded rule.

## Detecting an outage

`.claude/scripts/ci_availability_check.sh` (exit 0 available, 1 unavailable,
2 usage, 3 indeterminate). The session banner shows `ci:ok`,
`ci:UNAVAILABLE` or `ci:unknown` (cached; refreshed in the background).
`ci:unknown` means "could not determine" (gh missing, auth failure, a single
uncorroborated `startup_failure`) and must never be read as `ci:ok`. A 401
with a stale `GH_TOKEN` maps to unknown, not unavailable.

## Which local command stands in for which gate

Verified against `.github/workflows/` and the tree on 2026-09-21. The issue
text names `verify.sh`, `build.sh` and `regen_api_context.sh`; none of these
exist in this repo, so they are not listed. Use the real commands below.

| CI workflow | What it does | Local stand-in |
|---|---|---|
| `private-data-scan.yml` | selftest + PII scan of the PR range (generic patterns) | `bash .claude/scripts/private_data_scan.sh --selftest` then `bash .claude/scripts/private_data_scan.sh --range origin/main HEAD` (locally the deny-list is also active, so this is stronger than CI) |
| `skill-security-scan.yml` | skill diff security scan | `bash .claude/scripts/check_skill_security.sh --diff origin/main --severity high --fix-hints` |
| `cross-repo-symlink-check.yml` | cross-repo symlink audit | `bash .claude/scripts/check_cross_repo_symlinks.sh` |
| `wiki-sync-check.yaml` | README wiki markers, `WIKI_CONTENT/` present, generated block matches | Steps are inline in the workflow, no single script exists: read `.github/workflows/wiki-sync-check.yaml` and run its checks by hand |
| `vignette-validation.yml` (reusable, `workflow_call`) | `vig_*` targets exist, no computation in vignettes | `bash .claude/scripts/vignette_check.sh`; targets check needs `nix-shell <project>/default.nix` |
| `quarto-publish.yaml` (build job) | `quarto render`, HTML error scan, blank-plot scan, link check | `quarto render`, then `Rscript -e 'source("R/tar_plans/plan_qa_gates.R"); scan_html_for_errors("docs")'` and `check_no_blank_plots("docs")`, plus `bash .claude/scripts/check_internal_links.sh`. The deploy job is CI-only and cannot be substituted |
| `coverage.yml` | `covr::package_coverage()`, commits `inst/extdata/coverage.rds` | Informational only; `Rscript -e 'covr::package_coverage()'` via the project nix shell. Do not hand-commit coverage.rds |
| (no workflow) code quality | ast-grep + jarl | `~/.claude/scripts/r_code_check.sh R/` |
| (no workflow) shell tests | `tests/test_*.sh` | run the ones for the scripts you changed, foreground |
| (no workflow) merge gate | roborev findings | `bin/roborev_merge_gate.sh <pr#>` (exit 3 = indeterminate, not pass) |

## PR and merge rules while CI is unavailable

- The PR body must say `CI unavailable` and list which local gates above were
  run, with their result (`.github/PULL_REQUEST_TEMPLATE.md` carries the line).
- The Auto-Merge Policy requires every CI check to report success; with CI
  absent that cannot be met, so PR merge stays Class C (explicit verb) even
  when the toggle is ON.
- A local gate you did not run is "not run", not "passed".

## Freshness: attribute scheduled-data gaps to the outage, not the source

Scheduled data-poll workflows skip during an outage, so a stale dataset can be
mistaken for a dead source. The committed, append-only ledger
`.claude/state/ci_outages.tsv` (`start_date`, `end_date_or_open`, `reason`,
`source`) records the windows. A freshness check that finds a stale asset
should, before blaming the source, test whether the staleness window overlaps
a ledger row:

```bash
awk -F'\t' -v d="$STALE_SINCE" 'NR>1 && $1<=d && ($2=="open" || $2>=d)' .claude/state/ci_outages.tsv
```

(ISO dates compare correctly as strings.) A match means "possibly caused by
a CI outage", not "proven"; report it as such. The workflows themselves are
not modified by this mechanism.

Maintain the ledger with the script, never by hand:

```bash
bash .claude/scripts/ci_availability_check.sh --record-start "<reason>" "<source>"
bash .claude/scripts/ci_availability_check.sh --record-end
```

`--record-end` rewrites only the end field of the single open row.

## Prevention (not implemented)

An alert at a spend threshold is deliberately not built: the billing usage
endpoint (`gh api /users/<owner>/settings/billing/usage`) is readable and
reports usage, but the budget/limit itself is not exposed there, so a
threshold could not be verified. See #761 (R-Universe CI-minute conservation).
