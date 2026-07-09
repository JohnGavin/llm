# Companion: Nix Agent Shell — Overlay-Recovery Workflow + Incident Log

Detailed recovery workflow and the dated incident narratives split out of the always-loaded [`nix-agent-shell-protocol`](../nix-agent-shell-protocol.md) rule. The **normative MANDATORY pattern** (use cwd-safe Form A / Form B, never a bare absolute path) stays in the rule (see its "MANDATORY pattern when an agent regenerates a worktree's `default.nix`" section). This file is the incident evidence + the step-by-step overlay-recovery procedure, loaded on demand when actually regenerating a `default.nix` that carries hand-edited overlays.

### Lesson logged 2026-05-02

In the acd_area_climate_design project, a Stage 2 OSM agent regenerated default.nix in its worktree but the cwd resolved to the orchestrator's main checkout, stripping the udunits + shellHook patches. Detected when the orchestrator's render failed. Restored from HEAD. Filed observation issue and amended the rule.

### Lesson logged 2026-05-08

In the mycare project, regenerating default.nix to add testthat/here/withr stripped a manual `python312Packages.overrideScope` (`twisted.doCheck = false`) overlay needed to bypass the upstream pdfplumber → pandas → ibis → twisted test-failure cascade (JohnGavin/llm#62). The shellHook itself survived (it lives in default.R), but the nixpkgs overlay block — between the `let` keyword and the `pkgs = ...` line — does not, because rix() does not preserve hand-edited overlays.

**Defensive workflow when regenerating default.nix:**

Every regeneration call MUST use cwd-safe Form A (subshell) or Form B
(`setwd()`), as documented in the parent rule. There is no safe exception: even when
the caller appears to be in the right directory, worktree-orchestrator cwd
drift can silently overwrite the wrong checkout.

- **Form A** (subshell): `(cd /absolute/path/to/project && nix-shell ~/docs_gh/llm/default.nix --run "Rscript default.R")`
- **Form B** (setwd): `nix-shell ~/docs_gh/llm/default.nix --run "Rscript -e 'setwd(\"/absolute/path/to/project\"); source(\"default.R\")'")`
- **NEVER** use a bare absolute path: `nix-shell ... --run "Rscript /absolute/path/to/project/default.R"` — this is the pattern that caused the 2026-05-02 and 2026-05-08 incidents.

Preferred — use a `default.post.sh` per project (idempotent shell script
that re-applies the project's overlays):

1. Regenerate using Form A:
   `(cd /absolute/path/to/project && nix-shell ~/docs_gh/llm/default.nix --run "Rscript default.R")`
2. `(cd /absolute/path/to/project && ./default.post.sh)` —
   re-apply overlays. Script must be idempotent and detect
   "already applied" via a `grep -q "marker" "$NIX_FILE"` guard.
3. Verify by entering the shell and loading affected packages.

Fallback — when no `default.post.sh` exists yet:

1. `cp /absolute/path/to/project/default.nix /absolute/path/to/project/default.nix.pre-regen.bak`
2. Regenerate using Form A:
   `(cd /absolute/path/to/project && nix-shell ~/docs_gh/llm/default.nix --run "Rscript default.R")`
3. `diff /absolute/path/to/project/default.nix.pre-regen.bak /absolute/path/to/project/default.nix` — eyeball stripped sections
4. Re-apply overlays manually
5. Verify
6. `rm /absolute/path/to/project/default.nix.pre-regen.bak`
7. **Capture the manual steps as a `default.post.sh`** so the next regen
   is automatic (and add `default.nix.bak` to `.gitignore`).

Survey for hand-crafted overlays before regen with:
`grep -E "extend|overrideScope|overridePythonAttrs|disabledTestPaths" default.nix`

Known projects with `default.post.sh`:

| Project | Overlay re-applied | Reason |
|---|---|---|
| `mycare` | `python312Packages.twisted.doCheck = false` | pdfplumber→pandas→ibis→twisted build cascade (JohnGavin/llm#62) |
