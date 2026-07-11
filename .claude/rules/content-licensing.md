---
description: Public-project licensing policy — content (docs, vignettes, wiki, figures, data) under CC BY 4.0; code stays under its OSS licence (MIT/etc.). Never put source code under a CC licence.
paths:
  - "**/LICENSE*"
  - "**/DESCRIPTION"
  - "**/README.qmd"
  - "**/README.md"
  - "**/_quarto.yml"
---

# Rule: Public-Project Licensing Policy

## Decision

[#767](https://github.com/JohnGavin/llm/issues/767), decided 2026-07-11
(**Option 3**): standardise public projects on a **content vs code** split.

| Layer | Licence | Applies to |
|---|---|---|
| **Content** | **CC BY 4.0** (Attribution) | vignettes, docs, pkgdown/Quarto sites, wiki prose, diagrams, figures, datasets |
| **Code** | existing **OSS licence** (MIT unless the repo already differs) | `R/`, `inst/`, scripts, `.github/`, anything that executes |

CC BY 4.0 was chosen over BY-NC-SA to **maximise reach and compatibility**:
attribution only, no NonCommercial ambiguity, ShareAlike dropped, Wikipedia/OER
compatible. The trade-off accepted: no protection against commercial
repackaging of our writing.

## CRITICAL: Never put source code under a Creative Commons licence

Creative Commons **explicitly recommends against CC licences for software** —
they don't address source-vs-object code or patent grants and aren't
OSI-approved. For R packages this also breaks CRAN-readiness (`DESCRIPTION`
`License:` must be a recognised software licence). Code stays OSS; only content
is CC.

## Application

- **`DESCRIPTION` `License:`** — set/keep the software (OSS) licence via the
  standard SPDX id; CRAN does not validate content licences.
- **Content licence** — add a `LICENSE.content.md` (or a `## Licence` README
  section) stating "Documentation and other content in this repository are
  licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/);
  source code is licensed under <OSS licence>." Link the deed.
- **README `## Licence` section** — state the split in one short paragraph so
  reusers see it immediately.
- **pkgdown/Quarto sites** — add a footer attribution + CC BY 4.0 link.

## Scope and exemptions

- Applies to **public** repos only.
- The local-only `knowledge/` hub is **never published** — CC does not apply;
  exclude it explicitly (it already carries a `PRIVATE` marker + pre-push block).
- Private/PHI repos (e.g. `mycare`) are out of scope.
- Rollout to existing public repos is phased and confirmed per repo — see #767;
  dead scaffolds are not licensed (subtractive-first).

## Forbidden patterns

| Pattern | Why wrong | Fix |
|---|---|---|
| CC BY 4.0 in `DESCRIPTION` `License:` | Not a recognised software licence; breaks CRAN | OSS licence for code; CC for content only |
| CC BY-NC / -SA re-introduced without a new decision | Reverses #767 (NC ambiguity, incompatibility) | Keep CC BY 4.0 unless #767 is superseded |
| Content licence added to the `knowledge/` hub | Hub is local-only, never published | Exclude; it is not a public project |

## Related

- [#767](https://github.com/JohnGavin/llm/issues/767) — decision + full option analysis.
- `knowledge-base-wiki` skill / `wiki-storage-policy` — the local-only hub is out of scope.
- `press-release-first` — companion governance rule created in the same PR.
