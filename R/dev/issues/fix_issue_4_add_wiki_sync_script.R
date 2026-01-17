# Issue #4: Add helper script to sync WIKI_CONTENT to GitHub wiki and keep README in sync
#
# Created via:
#   gh::gh(
#     \"POST /repos/{owner}/{repo}/issues\",
#     owner = \"JohnGavin\",
#     repo = \"llm\",
#     title = \"Add helper script to sync WIKI_CONTENT to GitHub wiki and keep README in sync\",
#     body = \"...\"\n+#   )
#
# Implementation notes:
# - Added `R/dev/wiki/sync_wiki.R` which:
#   - clones `llm.wiki.git` (HTTPS) using `GITHUB_PAT`
#   - copies all `WIKI_CONTENT/*.md` into the wiki repo as pages
#   - updates the wiki `Home.md` Documentation section
#   - regenerates the `README.md` docs block between markers
#
# Run:
#   Rscript R/dev/wiki/sync_wiki.R

