# Companion: roborev exclude_patterns — Case Study + Audit Results

Case-study detail and the one-time audit table split out of the
always-loaded [`roborev-exclude-patterns`](../roborev-exclude-patterns.md)
rule to keep it lean. The normative content (Source, CRITICAL statement,
Required Pattern, Forbidden Patterns, How to Add to a New Repo) stays in the
rule; this file is the case-study detail and the dated audit, loaded on
demand.

## Minimum file contents — worked example

```toml
exclude_patterns = [
  "CHANGELOG.md",
  ".claude/CURRENT_WORK.md",
]
```

## Case study — llmtelemetry (2026-07-22) — full detail

`llmtelemetry` receives ~400 commits/week, effectively **100% bot-authored**:
`data: update telemetry data` (regenerated JSON/parquet under `inst/extdata/**`)
and `chore: Auto-refresh ccusage cache`. roborev reviewed every one. Result over
7 days: **234 findings (104 High, 103 Medium) at a 16.7% close rate** — vs single
digits for every other repo. None were real bugs; a reviewer pointed at
regenerated data flags spurious churn ("value changed", "count differs").

Fix applied — a `.roborev.toml` excluding the generated-data paths, so a
data-only commit presents an empty diff and produces no findings, while real
`R/`/`scripts/` commits are still reviewed:

```toml
exclude_patterns = [
  "inst/extdata/**",     # automated telemetry data + ccusage cache
  "vignettes/data/**",   # dashboard data exports
  "CHANGELOG.md",
  ".claude/CURRENT_WORK.md",
]
```

~230 already-accumulated open **single-data-commit** findings were bulk-closed
as won't-fix (`roborev close <id>` per review). **Left untouched — verify before
mass-closing:**

- `range` batch-reviews (`job_type=range`, `commit_subject=null`, `git_ref=SHA..SHA`):
  these span a *range* of commits — inspect the range (`git log A..B`) before
  assuming noise. In llmtelemetry the range reviews covered mostly **real code**
  (fixes/features from an earlier dev period), not data refreshes — closing them
  blindly would have destroyed legitimate findings.
- Single real-code reviews (`fix:`/`feat:`/merges) — genuine triage.
- Crashed jobs (`verdict=null status=failed`) — the gemini-crash artifacts;
  `roborev close` cannot address them (no verdict to resolve). They are a
  separate problem (agent health), not findings, and clear via re-run/purge.

## Audit Results — 2026-05-21

Repos checked for `.roborev.toml` + CHANGELOG.md status:

| Repo | `.roborev.toml` | `CHANGELOG.md` | `exclude_patterns` covers CHANGELOG? | Action needed |
|------|----------------|----------------|--------------------------------------|---------------|
| `historical` (reference) | Yes | Yes | Yes — `4906b6d` | None — compliant |
| `llm` | Yes | Yes | No — `exclude_patterns = []` | Add entries |
| `crypto_solwatch` | Yes | No | n/a | No CHANGELOG to exclude |
| `llmtelemetry` | Yes | Yes | Yes — `inst/extdata/**` + `vignettes/data/**` + ledger (2026-07-22) | None — compliant |
| `mycare` | No | No | n/a | No action needed |
| `irishbuoys` | No | No | n/a | No action needed |
| `footbet` | No | No | n/a | No action needed |
| `randomwalk` | No | No | n/a | No action needed |
| `urban_planning` | No | No | n/a | No action needed |
| `acd_area_climate_design` | No | No | n/a | No action needed |
| `crypto_swarms` | No | No | n/a | No action needed |

**Priority actions from this audit:**
1. `llm` — has both files; `exclude_patterns = []` → needs the two entries added.
2. `llmtelemetry` — has CHANGELOG.md; check if roborev is enabled and add toml if so.
