# Archived plans

Plans created via the `writing-plans` skill that are either complete or
target a different project. Kept here for provenance — many of these plans
were authored in this repo for cross-project work and the work has since
landed elsewhere.

## What's here

| File | Target project | Topic |
|---|---|---|
| federated-fluttering-lemon.md | personal site (johngavin.github.io) | Hugo → Quarto migration |
| glistening-hopping-koala.md | llm | Prediction calibration tracking (llm#47) |
| humble-squishing-unicorn.md | llmtelemetry | Output QA defence-in-depth |
| noble-humming-charm.md | irishbuoys | HuggingFace Parquet hosting (#71) |
| parsed-nibbling-dove.md | footbet | Falsification leaderboard tab + real-vs-sim quiz (#69, #70) |
| quirky-kindling-candle.md | micromort | Causes of Death by Country pure-JS vignette |
| rippling-cooking-kite.md | crypto_swarms | Phase 1 fixes + Phase 2 architecture |
| soft-roaming-kitten.md | llm | Skill directory convention + automated audit |
| vivid-giggling-flask.md | acd_area_climate_design | Single-page multi-country sea-distance dashboard |

## Going forward

Plans for *this* project (llm) live in `.claude/plans/`.
Plans for other projects should be authored in those projects'
own `.claude/plans/` directories — not here.

## Rollback

Any of these can be restored to the active plans directory:

```bash
git -C ~/docs_gh/llm mv .claude/plans/archive/<slug>.md .claude/plans/
```

Or restored from before the archive commit:

```bash
git -C ~/docs_gh/llm log --oneline -- .claude/plans/  # find the archive commit
git -C ~/docs_gh/llm revert <archive-commit-sha>
```
