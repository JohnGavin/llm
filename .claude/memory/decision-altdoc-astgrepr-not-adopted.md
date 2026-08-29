---
name: decision-altdoc-astgrepr-not-adopted
description: Evaluated altdoc (pkgdown alternative) and astgrepr (R ast-grep bindings) 2026-08-28 — decided not to adopt either; cite this instead of re-researching
metadata: 
  node_type: memory
  type: project
  originSessionId: 80bc1998-ea06-458a-a97c-dc85dc150faf
  modified: 2026-08-28T18:24:10.188Z
---

Decision (2026-08-28): evaluated both packages by Etienne Bacher, on the
user's request, and decided to **stick with pkgdown and the CLI-based
ast-grep workflow** — do not adopt either without a new, explicit ask.

**altdoc** (https://altdoc.etiennebacher.com/, backends: Quarto/Docsify/MkDocs/
Docute, on CRAN, MIT, single-maintainer, ~86 GH stars / 517 commits at eval
time) — a pkgdown alternative. Rejected because: pkgdown is already deeply
wired into this project's own tooling (dark-contrast gate,
`qa_methodology_blocks`/`qa_build_info_blocks` gates, R-universe build-status
checks — all built around pkgdown's specific HTML output conventions);
switching would mean re-deriving all of that. The one attractive pull
(MkDocs-material's nicer theme) requires a Python toolchain, cutting against
Nix-purity and "R preferred over Python". altdoc's own README states no
comparison/case against pkgdown — the tradeoff is ours to make, not one they
argue for. Its doc site (the URL above) returned an empty page on WebFetch
(likely JS-rendered) — the facts above came from its GitHub README instead.

**astgrepr** (https://astgrepr.etiennebacher.com/, CRAN v0.1.2, R bindings to
the same ast-grep Rust engine already used via CLI, needs a Rust toolchain to
build from source) — a native-R alternative to shelling out to the ast-grep
CLI. Not adopted for the existing `r_code_check.sh` /
`~/.config/ast-grep/rules/` workflow — that workflow is battle-tested against
real gotchas already paid for (see [[feedback_ast-grep-lessons]]: R
custom-grammar config trap, bare `$$$` silently-never-matching trap), and
switching risks re-discovering them in a v0.1.2, single-maintainer wrapper.
Flagged as a *possible* narrow fit for writing bespoke structural checks
natively in R inside `plan_qa_gates.R` (e.g. for the #892/#800 QA-gate work
planned in [llm#1058](https://github.com/JohnGavin/llm/pull/1058)) — but only
as a small scoped trial on one gate, never a replacement for the CLI
workflow. `flir` (an ast-grep-based R linter, also by Etienne Bacher) is a
separate sibling package, not documented on the astgrepr site itself.

**How to apply:** if asked again to evaluate altdoc or astgrepr for this
project, cite this decision and the reasons above rather than re-running the
research from scratch. Re-open only if project constraints materially change
(e.g. Nix-purity/Python-avoidance is relaxed, or astgrepr matures past
v0.1.x with broader community adoption).
