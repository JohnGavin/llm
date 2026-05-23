# MVP Plan: Cross-Repo Roborev Handoff — Phase 1a Only

> **Pilot target updated 2026-05-23: crypto inactive → randomwalk**
> All §7 pilot references changed from `crypto` to `randomwalk`. See `plans/149-handoff-pilot-report.md` for dry-run output and the manual `--apply` command.

**Issue:** [JohnGavin/llm#149](https://github.com/JohnGavin/llm/issues/149)
**Plan source:** `.claude/plans/cross-repo-roborev-handoff.md` (full plan, all phases)
**MVP scope:** Phase 1a only — per-commit fail issues; Phases 1b and 1c deferred

---

## 1. Existing Plan Summary

Key decisions locked 2026-05-13 in `cross-repo-roborev-handoff.md`:

| Decision | Value |
|---|---|
| Default handoff mechanism | A — GitHub issue (opt into B via `<root>/.claude/.roborev-handoff-mode = inbox`) |
| Handoff threshold | 7 days after job `finished_at` |
| Phase 1a | verdict=fail → one GH issue per `commit_sha`, label `roborev-handoff` |
| Phase 1b | verdict=pass+comments → weekly digest issue per repo per ISO-week, label `roborev-digest`; append-on-existing, script never closes |
| Phase 1c | verdict=pass clean → silent close, nothing surfaces |
| Idempotency | search by sha before create (1a); grep `job <id>` before append (1b) |
| Close ordering | close roborev job ONLY after handoff success; failure leaves job open for retry |
| Issues disabled fallback | fall back to Mechanism B if `hasIssuesEnabled=false` |

The script `~/.claude/scripts/roborev_handoff.sh` already exists and implements all three phases (1a, 1b, 1c) plus Mechanism B. The MVP plan is about **sequencing validation**, not rewriting the script.

---

## 2. MVP Scope Recommendation

Ship **Phase 1a only** (verdict=fail → per-commit GH issues) in the first PR.

**Rationale:**

- Phase 1a is the highest-value path: real bugs in target repos stop being lost.
- Phase 1b (weekly digests) is lower urgency — pass-with-comments findings are non-blocking.
- Phase 1c (silent close) is already trivially safe but has no user-visible benefit on its own.
- Validating 1a end-to-end first de-risks the GH API interaction pattern (search, create, label) before 1b adds the more complex append-and-idempotency path.
- The existing script supports `--apply` gated on manual confirmation; 1b can be added in a single follow-up commit once 1a is verified.

---

## 3. Implementation Slice — Phase 1a MVP

The script already exists. The MVP is about verifying the slice that matters:

### Files in scope

| File | Status | What's needed for 1a MVP |
|---|---|---|
| `~/.claude/scripts/roborev_handoff.sh` | EXISTS (all phases) | No changes needed; the 1a path is already implemented |
| `.claude/plans/cross-repo-roborev-handoff.md` | EXISTS | Already documents the full plan |
| `plans/149-handoff-mvp.md` | THIS FILE | Scopes the sequencing |

### Behaviour to verify

1. **`--dry-run` (default):** for 3 manually-picked stale `verdict=fail` jobs, the script prints `[dry] <repo>: would create GH issue (commit <sha>, job <id>, label roborev-handoff)` and exits 0 without touching GH.

2. **`--apply` single-repo pilot:** `ROBOREV_REPO=randomwalk ~/.claude/scripts/roborev_handoff.sh --apply` creates one GH issue per stale fail job in `randomwalk` with:
   - Title: `roborev review for <7-char sha>`
   - Label: `roborev-handoff`
   - Body: review markdown + `roborev job: <id>` footer

3. **Idempotency:** re-running `--apply` on the same repo produces no new issues (search finds existing ones, job stays open if already closed).

4. **Close ordering:** roborev job closes AFTER `gh issue create` returns 0; if `gh issue create` fails, job stays open (visible in `~/.claude/logs/roborev_handoff.log`).

5. **Fallback:** if `crypto` has `hasIssuesEnabled=false`, the script falls back to Mechanism B (appends to `CURRENT_WORK.md`) without erroring.

---

## 4. Out of Scope for This MVP

| Feature | Phase | Reason for deferral |
|---|---|---|
| Weekly pass-comments digest | 1b | Lower urgency; more complex append/idempotency; verify 1a GH API pattern first |
| Silent close for pass-clean | 1c | Safe but no user value until 1a/1b are shipping |
| Mechanism B (`CURRENT_WORK.md` inbox) | 1a opt-in | Script already implements it; test only as fallback from 1a |
| Wiring into `com.claude.roborev-autoclose.plist` | Phase 4 | After ≥1 week of Phase 3 stable (multiple repos, no spurious issues) |
| `session_init.sh` banner for `roborev-handoff` labelled issues | Owner side | After handoff issues are being created reliably |

---

## 5. MVP Acceptance Criteria

All distinct from the full issue's acceptance checklist:

- [ ] `roborev_handoff.sh --dry-run` (no args) runs without error on the current DB; output lists at least one `[dry] ... would create GH issue` line (or "nothing to do" if DB is empty)
- [ ] `ROBOREV_REPO=randomwalk roborev_handoff.sh --apply` creates ≥1 GH issue in `JohnGavin/randomwalk` with label `roborev-handoff` OR exits cleanly with "nothing to do"
- [ ] Re-running `--apply` on the same repo within 60 seconds produces zero new issues (idempotency gate)
- [ ] `~/.claude/logs/roborev_handoff.log` contains a `1a: created issue` line AND a `1a: closed job=` line for the same job_id
- [ ] If `gh issue create` is forced to fail (e.g., `GH=/usr/bin/false`), the roborev job remains open (close-after-success ordering)

Phase 1b, 1c, and plist wiring are NOT acceptance criteria for this PR.

---

## 6. Top Risks and Mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| GH rate-limit on repos with many stale fail jobs | Medium | Script already logs and leaves job open on API failure; re-run next day |
| Duplicate issues from concurrent `--apply` runs (two launchd invocations overlap) | Low | Idempotency search reduces window; the sha search is not atomic but concurrent runs are rare given weekly launchd trigger |
| Target repo has `roborev-handoff` label missing, causing `gh issue create` to fail | Medium | Pre-flight the pilot: `gh label create roborev-handoff --repo JohnGavin/randomwalk --color 8B5CF6` before first `--apply`; add to the rollout checklist |

---

## 7. Pilot Target

Use **`randomwalk`** as the first `--apply` target. Rationale:

- `crypto` is inactive (user decision 2026-05-23); `randomwalk` is the replacement pilot.
- Active dev repo with 7 confirmed stale verdict=fail candidates (verified 2026-05-23).
- Has GitHub issues enabled (confirmed: `hasIssuesEnabled=true`).
- Any spurious issues are easy to identify and close.

Pilot sequence:
1. `sqlite3 ~/.roborev/reviews.db "SELECT COUNT(*) FROM review_jobs rj JOIN repos r ON r.id=rj.repo_id JOIN reviews rv ON rv.job_id=rj.id WHERE r.name='randomwalk' AND rj.status='done' AND (julianday('now')-julianday(rj.finished_at))>7 AND rv.verdict_bool=0"` — confirms 7 candidates (verified 2026-05-23)
2. Ensure `roborev-handoff` label exists in `JohnGavin/randomwalk`
3. `ROBOREV_REPO=randomwalk ~/.claude/scripts/roborev_handoff.sh` (dry-run first)
4. Inspect dry-run output
5. `ROBOREV_REPO=randomwalk ~/.claude/scripts/roborev_handoff.sh --apply`
6. Verify issue on GitHub; verify log; verify idempotency

---

## 8. Follow-Up Slices (Three PRs After MVP)

| PR | Content | Unblock condition |
|---|---|---|
| **1b-digest** | Enable the `pass-comments` digest path in `--apply`; verify append-idempotency with `job <id>` grep | 1a MVP stable for ≥3 days with no spurious issues |
| **1c-silent-close** | Enable `pass-clean` silent close in `--apply`; verify no false positives (classification must match `^No issues found\.`) | 1b-digest merged |
| **plist-wiring** | Add `roborev_handoff.sh --apply` call to `com.claude.roborev-autoclose.plist`; add `session_init.sh` Phase banner for `roborev-handoff` issues | ≥1 week of Phase 3 (all repos) stable |

---

## 9. Interaction with Related Issues

| Issue | Overlap | Resolution |
|---|---|---|
| [#163](https://github.com/JohnGavin/llm/issues/163) — Automate closure loop | #163 Phase 4 auto-verifier closes findings when roborev re-approves a fix commit. #149 creates GH issues in the target repo so the owner can act. These are complementary, not competing: #149 surfaces the finding; #163 closes it once fixed. No shared script. | Implement in parallel; #163 owner side picks up `roborev-handoff` issues created by #149. |
| [#163 MVP (#250)](https://github.com/JohnGavin/llm/issues/163) | If #250 lands before #149 pilot, the auto-verifier will expect `closes roborev #N` commit convention. #149 issues are in the target repo's tracker, not in roborev's DB — no conflict. | #149 does not depend on #163; proceed independently. |
| [#138](https://github.com/JohnGavin/llm/issues/138) — weekly autoclose | Existing plist cancels stale-failed (Phase 2) jobs. #149 adds a handoff step before close. The plist wiring (Phase 4 of #149) must ensure handoff runs before the Phase 2 cancel step. | Document in plist PR comments; test ordering explicitly. |
| [#145](https://github.com/JohnGavin/llm/issues/145) — broader roborev prompt | More reviews → more stale fail jobs → more handoff candidates. #149 benefits from #145 landing first, but is not blocked by it. | Ship #149 MVP now; re-run pilot after #145 lands to catch new categories. |

---

*Plan authored 2026-05-23. Implementation: see `~/.claude/scripts/roborev_handoff.sh` (all phases already coded; MVP is about sequenced validation, not new code).*
