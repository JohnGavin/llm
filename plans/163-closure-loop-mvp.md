# Plan: #163 closure-loop automation — MVP

**Issue:** [JohnGavin/llm#163](https://github.com/JohnGavin/llm/issues/163)
**Scope:** First PR only — Components 1 + 3. All other components deferred.
**Status:** Draft for review
**Author:** fixer agent (claude-sonnet-4-6), 2026-05-23

---

## 1. MVP scope

Ship **two** of the eight components in this PR:

| Component | Description | Rationale for shipping first |
|-----------|-------------|------------------------------|
| **1 — per-project backlog watcher** | Script reads `reviews.db`, writes `<project>/.roborev/backlog.md` | Pure read, zero mutation risk; immediately useful; unblocks human fixers |
| **3 — commit convention + pre-commit validator** | Enforces `fixes roborev #N` citation format; rejects bad citations at commit time | Prerequisite for all downstream automation (components 4/5 cannot function without a machine-parseable citation) |

**Deferred:** Components 2, 4, 5, 6, 7, 8 (see §4 below).

---

## 2. Order of work — file-by-file checklist

### Phase A — Backlog watcher (Component 1)

- [ ] **`.claude/scripts/roborev_project_backlog.sh`** (new script)
  - Args: `<project-name> [--apply | --dry-run]`
  - Reads `~/.roborev/reviews.db` (read-only `sqlite3.connect(..., uri=True, mode=ro)`)
  - Writes `<project-root>/.roborev/backlog.md` (create dir if needed)
  - Output: top-10 table sorted by `age_days DESC` (no composite score yet — Component 2 adds that)
  - Columns: `id | sev | category | age_days | one-line summary`
  - Safety: dry-run by default; `--apply` writes file; `--repo <name>` restricts scope
  - Fail-open: exits 0 if DB or binary missing (portability rule)
  - Self-test: `ROBOREV_BACKLOG_SELFTEST=1 bash script.sh` runs unit assertions

- [ ] **`.gitignore` (project-level)** — confirm `.roborev/` is already gitignored or add it
  - Check: `grep -q '\.roborev/' .gitignore || echo ".roborev/" >> .gitignore`

- [ ] **`launchd plist`** — `~/Library/LaunchAgents/com.claude.roborev-project-backlog.plist`
  - Runs daily at 09:00 for `--repo llm --apply`
  - Follows existing plist pattern from `com.claude.roborev-autoclose.plist`

- [ ] **`.claude/rules/roborev-resolution.md`** — add one sentence under "Per-Session Workflow":
  > "Check `.roborev/backlog.md` for prioritised open findings before starting fixes."

### Phase B — Commit convention (Component 3)

- [ ] **`.claude/scripts/roborev_citation_validate.sh`** (new script)
  - Reads `$1` (commit message file path, as passed by git pre-commit hook)
  - Parses `closes roborev #N` / `fixes roborev #N` / `wontfix roborev #N [reason: ...]` patterns
  - If IDs found: queries DB, verifies each ID exists AND `closed=0`
  - If any ID is already closed: exits 1 with actionable error
  - If DB unavailable: exits 0 (fail-open; don't block offline commits)
  - Self-test: `ROBOREV_CITE_SELFTEST=1 bash script.sh` covers: valid ID, already-closed ID, missing ID, no-citation (pass-through)

- [ ] **`git-hooks/commit-msg`** (extend existing hook or create)
  - Source `.claude/scripts/roborev_citation_validate.sh "$1"`
  - Installed via `roborev install-hook` or manual symlink

- [ ] **`.claude/rules/roborev-resolution.md`** — add "Commit Convention" subsection:
  - Document the three valid citation patterns
  - Note that won't-fix requires `[reason: ...]` tag (audit trail)
  - Note that the pre-commit hook fails-open when DB unavailable

- [ ] **`tests/testthat/test-roborev-citation.R`** (new test file) — _optional but recommended_
  - Calls `bash roborev_citation_validate.sh` with fixture commit messages
  - Asserts exit codes match expectations

---

## 3. Out of scope (this PR)

| Component | Why deferred |
|-----------|-------------|
| **2 — composite priority scorer** | Adds `file_heat` factor requiring git log analysis; adds complexity without blocking Component 1's immediate value |
| **4 — auto-verifier (post-commit)** | Load-bearing piece; needs DB schema migration (Component 4 creates `closures` + `fix_rejected_queue` tables) — too risky for MVP; needs Component 3 to be battle-tested first |
| **5 — scheduler (launchd for all projects)** | Depends on Component 1 being stable across all repos |
| **6 — visibility (badge, banner, digest)** | Vanity features until the loop itself works |
| **7 — safety guardrails (human gates)** | Only meaningful once auto-verifier (Component 4) ships |
| **8 — phased rollout** | Rollout schedule is a delivery concern, not an MVP concern |

**Also out of scope:**
- DB schema migration (`closures`, `fix_rejected_queue` tables)
- Cross-repo citation lookup (open design question #4 in the issue)
- Auto-dispatch of fixer agents (per the issue's own "out of scope" list)
- Auto-revert of rejected fix commits

---

## 4. Acceptance for the MVP

These criteria are **separate** from the issue's overall acceptance (which covers all 8 components):

| # | Criterion | How to verify |
|---|-----------|---------------|
| 1 | `roborev_project_backlog.sh --repo llm --dry-run` exits 0 and prints a valid markdown table | Manual run |
| 2 | `roborev_project_backlog.sh --repo llm --apply` writes `.roborev/backlog.md` in the llm checkout | `ls llm/.roborev/backlog.md` |
| 3 | Self-test passes: `ROBOREV_BACKLOG_SELFTEST=1 bash script.sh` → all PASS | CI |
| 4 | `roborev_citation_validate.sh` exits 1 for a commit citing an already-closed ID | Self-test |
| 5 | `roborev_citation_validate.sh` exits 0 for a commit with no roborev citations | Self-test |
| 6 | `roborev_citation_validate.sh` exits 0 when DB is absent (fail-open) | Self-test |
| 7 | Pre-commit hook installed in llm and fires the validator | `git commit` with bad citation → blocked |
| 8 | `.roborev/` gitignored in llm | `git check-ignore llm/.roborev/` |
| 9 | No existing tests regress | `devtools::test()` PASS |

---

## 5. Risks

| # | Risk | Likelihood | Impact | Mitigation |
|---|------|-----------|--------|-----------|
| 1 | **Pre-commit hook adds friction / breaks offline commits** | Medium | High — blocks developer workflow | Fail-open when DB unavailable (validator exits 0); keep validator fast (<100ms); document the bypass: `git commit --no-verify` as escape hatch |
| 2 | **Backlog watcher uses wrong project root path** — writes `backlog.md` to the wrong checkout (same cwd-drift risk as rix regeneration) | Medium | Medium — silent wrong output | Always resolve project root from DB `root_path` column, not from cwd; add assertion in self-test |
| 3 | **Commit convention adopted inconsistently** — developers don't know about it, make commits without citations, and the loop never fires | High | Medium — loop doesn't close anything, but no regression | The validator is passive at first (warns, doesn't block); documentation update to `roborev-resolution.md` is mandatory in this PR; address Component 6 (visibility) in slice 2 to surface the convention |

---

## 6. Next slices (after MVP lands)

| Slice | Components | Dependencies | Notes |
|-------|-----------|-------------|-------|
| **Slice 2** | Component 2 (prioritiser) + Component 6 (session-init banner) | Slice 1 landed | Add composite score to backlog watcher; surface addressed-rate in session-init Phase 14; low DB-mutation risk |
| **Slice 3** | Component 4 (auto-verifier) + DB migration | Slice 1 landed, schema reviewed | Load-bearing; requires `closures` + `fix_rejected_queue` table migration; pilot on `t_demos` only |
| **Slice 4** | Component 5 (full scheduler) + Component 7 (safety guardrails) + Component 8 (rollout) | Slice 3 passed pilot | Expand auto-verifier to all projects; add human-gate for security/error-handling; weekly digest |

---

## 7. Integration with related issues

| Issue | Title | How MVP interacts |
|-------|-------|------------------|
| [#181](https://github.com/JohnGavin/llm/issues/181) | llm self-review backlog (92 open) | Component 1 backlog watcher makes the 92 open findings **visible and prioritised** in `.roborev/backlog.md`; MVP does not close them but reduces friction for human fixers working the backlog |
| [#217](https://github.com/JohnGavin/llm/issues/217) | Replace 24/7 poller with hook-driven design | Component 3 commit-citation hook is complementary — it fires at commit time (push-based), same direction as #217's goal of reducing polling noise; the two should be sequenced so #217 lands first or in parallel to avoid poller+hook double-coverage |
| [#241](https://github.com/JohnGavin/llm/issues/241) | Merge-gate: block PRs with open related findings | Component 3's citation parser is the **foundation** that #241's merge gate will re-use to identify which findings a PR claims to fix; MVP citation format must be stable before #241 can build on it |
| [#235](https://github.com/JohnGavin/llm/issues/235) | Overnight self-review (learn from past performance) | Orthogonal to MVP; overnight job reads interactions, not roborev findings; no shared state; can ship independently |

---

## Implementation notes

- Scripts follow the existing pattern in `roborev_autoclose.sh`:
  - `export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:..."` at top for launchd portability
  - `set -euo pipefail`
  - Python for all DB queries (avoids sqlite3 CLI pipe-splitting on multiline output — same pattern as `roborev_handoff.sh`)
  - WAL-safe read-only connection: `sqlite3.connect(f'file:{db}?mode=ro', uri=True)`
  - Log to `~/.claude/logs/roborev_project_backlog.log`
- Self-test pattern follows `roborev_severity_autoclose.sh` (`SELFTEST=1` env var, prints N/N PASS)
- Citation regex should be flexible: accept `closes`, `fixes`, `close`, `fix`, `wontfix` (case-insensitive); require `roborev #<int>` or `roborev#<int>` (no space variant also common)
