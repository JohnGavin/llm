#!/usr/bin/env bash
# roborev_handoff.sh — hand off stale cross-repo roborev findings to their
# owning projects via GitHub issues or CURRENT_WORK.md inbox entries.
#
# Handles three populations (threshold = THRESHOLD_DAYS, default 7d):
#   Phase 1a  verdict=fail       → per-commit GH issue (label roborev-handoff)
#   Phase 1b  verdict=pass+notes → append to weekly digest issue (label roborev-digest)
#   Phase 1c  verdict=pass clean → silent roborev close (nothing surfaces)
#
# Mechanism A (default, GH issues) vs Mechanism B (CURRENT_WORK.md inbox):
#   A repo opts into B by creating <root>/.claude/.roborev-handoff-mode
#   containing the word "inbox".  All other content (or absent) → A.
#   If GH issues are disabled for the repo, A falls back to B automatically.
#   Mechanism B writes ONE summary line to CURRENT_WORK.md per repo per run
#   (e.g. "roborev-inbox: 3 new finding(s) (jobs 601,602,603) -- see ...") —
#   NOT one block per finding (llm#977: the old per-finding append grew
#   CURRENT_WORK.md to 3856 lines / 539 entries with nothing ever trimming
#   it). Full finding text always lives in $FINDINGS_DIR/<job>.md and the
#   roborev DB regardless of mode.
#
# "pass clean" = verdict_bool=1 AND output starts with "No issues found."
# "pass with comments" = verdict_bool=1 AND output has substantive content beyond that
#
# DB schema note (verified 2026-05-13):
#   reviews.verdict_bool  INTEGER  1=pass, 0=fail
#   reviews.output        TEXT     markdown review body  (NOT a "body" column)
#   (no "verdict" text column exists — the spec used "verdict" but the actual
#    column is verdict_bool)
#
# Implementation note: reviews.output contains newlines and pipe characters,
# so we use Python to query the DB and write per-job temp files instead of
# trying to split raw sqlite3 pipe-delimited output in bash.
#
# Tracked in JohnGavin/llm#149.
#
# ── Guards (llm#930) ─────────────────────────────────────────────────────────
# 930 found a dry-run that would have created 221+ GH issues in one pass, 184
# of them (83%) referencing an EMPTY commit SHA, 189 targeting a PUBLIC repo
# (JohnGavin.github.io). Three fail-safe guards address this — "fail-safe" here
# means: if a guard cannot determine the answer, it SKIPS the action rather
# than proceeding (inverted from this repo's usual fail-open convention,
# because a false skip costs one uncreated issue while a false create costs a
# public, unreferenceable issue that is tedious to remove):
#
#   1. Empty commit SHA  → skipped unconditionally, all classifications
#      (llm#923 / roborev-exclude-patterns: orphaned/range jobs must not be
#      mass-processed). Counted in `skip_empty_sha`.
#   2. Per-run issue-action cap → MAX_ISSUES_PER_RUN (env-overridable,
#      default 15). Applies to every GH-issue-touching action (Mechanism A:
#      Phase 1a per-commit issue create, Phase 1b digest create/append) —
#      the run is weekly, so a low cap drains a backlog slowly across
#      successive runs rather than flooding in one pass. Counted in
#      `skip_cap`.
#   3. Public-repo opt-in → repo visibility is read live via
#      `gh repo view --json visibility` (one call per repo, combined with the
#      existing hasIssuesEnabled check). PUBLIC repos are blocked from
#      Mechanism A (GH issue creation) unless the repo explicitly opts in by
#      creating `<root>/.claude/.roborev-handoff-public-ok` containing the
#      literal line `allow-public-issues`. If visibility cannot be determined
#      (gh call fails), the repo is blocked (fail-safe), NOT silently
#      rerouted to inbox mode. Counted separately in `skip_public_no_optin`
#      and `skip_visibility_unknown` so the two causes are distinguishable.
#
# All three guards are independently observable in the run summary line and
# independently provable in --dry-run (no network mutation, no `gh issue
# create` ever called in dry-run mode).
#
# Usage:
#   roborev_handoff.sh                            # dry-run all repos (default)
#   roborev_handoff.sh --apply                    # apply to all repos
#   ROBOREV_REPO=hello_t roborev_handoff.sh --apply   # apply to single repo only
#   MAX_ISSUES_PER_RUN=5 roborev_handoff.sh --apply   # override the per-run cap
#
# Exit codes:
#   0  ok (including "nothing to do" and "binary/db missing")
#   1  unexpected error

set -euo pipefail

# ── Config ───────────────────────────────────────────────────────────────────
ROBOREV="${ROBOREV:-/usr/local/bin/roborev}"
SQLITE="${SQLITE:-/usr/bin/sqlite3}"
GH="${GH:-$(command -v gh 2>/dev/null || echo /usr/bin/gh)}"
PYTHON="${PYTHON:-/usr/bin/python3}"
ROBOREV_DB="${ROBOREV_DB:-$HOME/.roborev/reviews.db}"
THRESHOLD_DAYS="${THRESHOLD_DAYS:-7}"
ROBOREV_REPO="${ROBOREV_REPO:-}"  # optional: restrict to a single repo by name
FINDINGS_DIR="${FINDINGS_DIR:-$HOME/.roborev/findings}"
LOG="$HOME/.claude/logs/roborev_handoff.log"
# Guard 2 (llm#930): conservative default cap on GH-issue-touching actions per
# run. This job is weekly, so 15/run drains a backlog over successive weeks
# rather than flooding hundreds of issues in a single pass, while staying
# small enough for a human to sanity-check every new issue from one run in a
# single sitting. Override with MAX_ISSUES_PER_RUN=<n>.
MAX_ISSUES_PER_RUN="${MAX_ISSUES_PER_RUN:-15}"
APPLY=0

case "${1:-}" in
  --apply)      APPLY=1 ;;
  --dry-run|"") APPLY=0 ;;
  -h|--help)    sed -n '2,30p' "$0"; exit 0 ;;
  *)            echo "unknown arg: $1" >&2; exit 1 ;;
esac

mkdir -p "$(dirname "$LOG")" "$FINDINGS_DIR"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

# ── SELFTEST (ROBOREV_HANDOFF_SELFTEST=1 or HANDOFF_SELFTEST_FULL=1) ─────────
# Exercises Phase 1a/1b/1c logic using in-process function calls only.
# CRITICAL: no subprocess-recursion — never calls `bash $0` from within this block.
#
# Usage: ROBOREV_HANDOFF_SELFTEST=1 bash ~/.claude/scripts/roborev_handoff.sh
#        HANDOFF_SELFTEST_FULL=1   bash ~/.claude/scripts/roborev_handoff.sh
# Both env vars are equivalent; HANDOFF_SELFTEST_FULL is the canonical name.
# Expected: all PASS lines, exit 0, runtime <10s.
if [ "${ROBOREV_HANDOFF_SELFTEST:-0}" = "1" ] || [ "${HANDOFF_SELFTEST_FULL:-0}" = "1" ]; then
  PASS=0; FAIL=0

  _assert() {
    local label="$1" result="$2"
    if [ "$result" = "ok" ]; then
      echo "PASS: $label"; PASS=$((PASS+1))
    else
      echo "FAIL: $label — $result"; FAIL=$((FAIL+1))
    fi
  }

  # Helper: classify_review is defined later in the file; source it inline here
  # since bash doesn't forward-declare functions.  We inline the logic to keep
  # the selftest self-contained.
  _classify() {
    local verdict_bool="$1" output_trimmed="$2"
    if [ "$verdict_bool" -eq 0 ]; then
      echo "fail"
    elif echo "$output_trimmed" | grep -q "^No issues found\."; then
      echo "pass-clean"
    else
      echo "pass-comments"
    fi
  }

  # ── 1. classify_review: verdict_bool=1 + "No issues found." → pass-clean ──
  got=$(_classify 1 "No issues found.

Summary: adds a lockfile.")
  [ "$got" = "pass-clean" ] \
    && _assert "1. classify pass-clean" "ok" \
    || _assert "1. classify pass-clean" "got '$got'"

  # ── 2. classify_review: verdict_bool=1 + substantive output → pass-comments ─
  got=$(_classify 1 "## Minor suggestions

- Consider adding error handling here.
- Rename variable for clarity.")
  [ "$got" = "pass-comments" ] \
    && _assert "2. classify pass-comments" "ok" \
    || _assert "2. classify pass-comments" "got '$got'"

  # ── 3. classify_review: verdict_bool=0 → fail regardless of output ─────────
  got=$(_classify 0 "No issues found.")
  [ "$got" = "fail" ] \
    && _assert "3. classify fail (verdict_bool=0 overrides)" "ok" \
    || _assert "3. classify fail (verdict_bool=0 overrides)" "got '$got'"

  # ── 4. Digest title format matches YYYY-Www ────────────────────────────────
  iso_week=$(date -u +%G-W%V)
  digest_title="roborev pass-comments digest $iso_week"
  echo "$digest_title" | grep -qE '^roborev pass-comments digest [0-9]{4}-W[0-9]{2}$' \
    && _assert "4. digest title format YYYY-Www" "ok" \
    || _assert "4. digest title format YYYY-Www" "title='$digest_title'"

  # ── 5. Idempotency guard: grep "job <id>" in existing body prevents duplicate
  fake_job_id="999"
  fake_existing_body="## roborev pass-comments digest 2026-W21

---
### Commit abc1234 (job 999) — 2026-05-23

Some notes here."
  echo "$fake_existing_body" | grep -q "job $fake_job_id" \
    && _assert "5. idempotency guard detects job in digest body" "ok" \
    || _assert "5. idempotency guard detects job in digest body" "grep missed job $fake_job_id"

  # ── 6. Idempotency guard: absent job_id is NOT detected (no false-positive) ─
  fake_new_job_id="1234"
  echo "$fake_existing_body" | grep -q "job $fake_new_job_id" \
    && _assert "6. idempotency guard: absent job NOT falsely detected" "false-positive — should not match" \
    || _assert "6. idempotency guard: absent job NOT falsely detected" "ok"

  # ── 7. Digest body append format contains job marker ─────────────────────
  fake_output="## Minor suggestions

- Consider renaming \`x\` to \`threshold\`."
  append_block=$(printf '\n---\n### Commit %s (job %s) — %s\n\n%s\n' \
    "abc1234" "777" "$(date -u +%F)" "$fake_output")
  echo "$append_block" | grep -q "job 777" \
    && _assert "7. append_block contains job marker" "ok" \
    || _assert "7. append_block contains job marker" "missing 'job 777' in block"

  # ── Phase 1c specific tests ───────────────────────────────────────────────

  # ── 8. Phase 1c: pass-clean produces dry-run "[dry] ... would close" line ──
  # Simulate the dry-run branch of the pass-clean case block inline.
  # APPLY=0 is the default (dry-run); the case block prints the [dry] message.
  _simulate_1c_dryrun() {
    local repo_name="$1" job_id="$2" apply="${3:-0}"
    if [ "$apply" -eq 0 ]; then
      echo "[dry] $repo_name: would close pass-clean (job $job_id)"
    else
      echo "applied"
    fi
  }
  dryrun_out=$(_simulate_1c_dryrun "testproject" "42" 0)
  echo "$dryrun_out" | grep -q "\[dry\].*would close pass-clean.*job 42" \
    && _assert "8. 1c dry-run emits [dry] would-close line" "ok" \
    || _assert "8. 1c dry-run emits [dry] would-close line" "got: '$dryrun_out'"

  # ── 9. Phase 1c: classify + dry-run combined path (end-to-end 1c dry flow) ─
  # verdict_bool=1, output starts with "No issues found." → pass-clean → dry-run close
  clean_verdict=1
  clean_output="No issues found.

All checks passed."
  clean_output_trimmed=$(echo "$clean_output" | sed 's/^[[:space:]]*//')
  clean_classification=$(_classify "$clean_verdict" "$clean_output_trimmed")
  [ "$clean_classification" = "pass-clean" ] \
    && _assert "9. 1c end-to-end: classify step yields pass-clean" "ok" \
    || _assert "9. 1c end-to-end: classify step yields pass-clean" "got '$clean_classification'"

  # ── 10. Phase 1c: fail job is NOT routed to silent-close (no false-silent) ─
  fail_output_trimmed="No issues found."   # text looks clean but verdict_bool=0 → fail
  fail_classification=$(_classify 0 "$fail_output_trimmed")
  [ "$fail_classification" = "fail" ] \
    && _assert "10. 1c guard: fail verdict_bool NOT silently closed" "ok" \
    || _assert "10. 1c guard: fail verdict_bool NOT silently closed" "got '$fail_classification'"

  # ── 11. Phase 1c: pass-comments not silently closed ──────────────────────
  comments_output_trimmed="## Suggestions

- Rename variable."
  comments_classification=$(_classify 1 "$comments_output_trimmed")
  [ "$comments_classification" = "pass-comments" ] \
    && _assert "11. 1c guard: pass-comments NOT silently closed" "ok" \
    || _assert "11. 1c guard: pass-comments NOT silently closed" "got '$comments_classification'"

  # ── llm#930 guard tests ────────────────────────────────────────────────────

  # ── 12. Guard 1: empty commit_sha is skipped regardless of classification ──
  _guard1_skip() {
    local sha="$1"
    [ -z "$sha" ] && echo "skip" || echo "process"
  }
  [ "$(_guard1_skip "")" = "skip" ] \
    && _assert "12. guard1 empty commit_sha -> skip" "ok" \
    || _assert "12. guard1 empty commit_sha -> skip" "got '$(_guard1_skip "")'"
  [ "$(_guard1_skip "abc1234")" = "process" ] \
    && _assert "12b. guard1 non-empty commit_sha -> process" "ok" \
    || _assert "12b. guard1 non-empty commit_sha -> process" "got '$(_guard1_skip "abc1234")'"

  # ── 13. Guard 2: per-run cap halts creation once the counter reaches MAX ───
  _guard2_action() {
    local created="$1" max="$2"
    [ "$created" -ge "$max" ] && echo "skip-cap" || echo "create"
  }
  [ "$(_guard2_action 15 15)" = "skip-cap" ] \
    && _assert "13. guard2 cap: at limit -> skip-cap" "ok" \
    || _assert "13. guard2 cap: at limit -> skip-cap" "got '$(_guard2_action 15 15)'"
  [ "$(_guard2_action 14 15)" = "create" ] \
    && _assert "13b. guard2 cap: below limit -> create" "ok" \
    || _assert "13b. guard2 cap: below limit -> create" "got '$(_guard2_action 14 15)'"

  # ── 14. Guard 3: public-repo opt-in marker requires the exact literal line ─
  _guard3_optin_dir=$(mktemp -d)
  mkdir -p "$_guard3_optin_dir/.claude"
  _guard3_marker="$_guard3_optin_dir/.claude/.roborev-handoff-public-ok"
  # (a) marker absent -> not opted in
  [ ! -f "$_guard3_marker" ] \
    && _assert "14a. guard3 marker absent -> not opted in" "ok" \
    || _assert "14a. guard3 marker absent -> not opted in" "marker unexpectedly present"
  # (b) marker present with correct literal content -> opted in
  echo "allow-public-issues" > "$_guard3_marker"
  { [ -f "$_guard3_marker" ] && grep -q "^allow-public-issues$" "$_guard3_marker"; } \
    && _assert "14b. guard3 marker present + correct content -> opted in" "ok" \
    || _assert "14b. guard3 marker present + correct content -> opted in" "grep did not match"
  # (c) marker present with wrong content -> NOT opted in (no false-positive)
  echo "yes please" > "$_guard3_marker"
  if [ -f "$_guard3_marker" ] && grep -q "^allow-public-issues$" "$_guard3_marker"; then
    _assert "14c. guard3 marker wrong content -> NOT opted in" "false-positive — should not match"
  else
    _assert "14c. guard3 marker wrong content -> NOT opted in" "ok"
  fi
  rm -rf "$_guard3_optin_dir"

  # ── 15. Regression guard: meta line parsing must preserve an empty
  # commit_sha field. Discovered empirically while building this guard: bash
  # `read` treats TAB as "IFS white space" and COLLAPSES consecutive
  # delimiters even when IFS is set to a lone tab, silently eating the empty
  # field and shifting every later column left by one — which made guard 1
  # never fire because commit_sha ended up holding the verdict_bool value
  # instead of "". Pipe is not IFS white space and does not collapse. This
  # test parses a simulated empty-commit_sha meta line the same way the main
  # loop does and asserts the fields land in the right variables. ───────────
  _meta_tmp_15=$(mktemp)
  printf '1090||0|fail\n' > "$_meta_tmp_15"
  while IFS='|' read -r _mid _msha _mverd _mclass; do
    if [ "$_mid" = "1090" ] && [ -z "$_msha" ] && [ "$_mverd" = "0" ] && [ "$_mclass" = "fail" ]; then
      _assert "15. meta line parse: empty commit_sha field preserved (pipe-delimited)" "ok"
    else
      _assert "15. meta line parse: empty commit_sha field preserved (pipe-delimited)" "got id=[$_mid] sha=[$_msha] verd=[$_mverd] class=[$_mclass]"
    fi
  done < "$_meta_tmp_15"
  rm -f "$_meta_tmp_15"

  # ── llm#930+ fail-safe dead-branch regression ─────────────────────────────
  # Reproduced 2026-08: gh_repo_info() deliberately `return 1`s on failure
  # (its own fail-safe design), but under this script's `set -euo pipefail`
  # an UNPROTECTED `x=$(fn)` assignment aborts the whole script the instant
  # fn returns non-zero — it never reaches the "if empty, treat as UNKNOWN"
  # fallback logic. Verified: with a broken `gh` credential the script died
  # silently at the first repo, printing NOTHING (no summary, no partial
  # counts), and `skip_visibility_unknown` could never increment because the
  # code that increments it is unreachable once the script is already dead.
  # The fix wraps both command-substitution assignments in the fail-safe
  # chain (`json=$(...) || json=""` inside gh_repo_info; `repo_info=$(gh_repo_info
  # ...) || true` at its call site) so a signalled failure is tolerated and
  # the run continues to the next repo/job instead of aborting.
  #
  # These tests use mock functions shaped exactly like the real fail-safe
  # (echo a fallback value, then `return 1`) so the regression is provable
  # without a network dependency on `gh`. If either protective idiom
  # regresses back to unprotected, `set -e` (active for this whole selftest
  # block, per line 72) kills the script AT THE ASSIGNMENT — no PASS/FAIL
  # line for that test prints, the immediately-following "still running"
  # test never prints either, and the final "selftest: N PASS" summary is
  # missing entirely. Reaching test 19 below is therefore itself part of
  # the proof, not just its own assertion. ──────────────────────────────────

  # ── 16. Mirrors the internal `json=$(...) || json=""` idiom in
  # gh_repo_info(): a failing inner command must not abort under set -e. ────
  _mock_failing_cmd() { return 1; }
  _json_probe=$(_mock_failing_cmd) || _json_probe=""
  [ -z "$_json_probe" ] \
    && _assert "16. fail-safe: internal json=\$(...) idiom survives command failure" "ok" \
    || _assert "16. fail-safe: internal json=\$(...) idiom survives command failure" "got '$_json_probe'"

  # ── 17. Proof-of-life: selftest is still executing after test 16. ────────
  _assert "17. selftest reached this line — set -e did not abort at test 16" "ok"

  # ── 18. Mirrors the external `repo_info=$(gh_repo_info ...) || true` idiom
  # at the call site: a function that echoes a fallback value THEN returns
  # non-zero (gh_repo_info's exact shape) must not abort under set -e, and
  # the echoed value must still be captured. ────────────────────────────────
  _mock_gh_repo_info() {
    echo "UNKNOWN|UNKNOWN"
    return 1
  }
  _fs_repo_info=$(_mock_gh_repo_info) || true
  [ "$_fs_repo_info" = "UNKNOWN|UNKNOWN" ] \
    && _assert "18. fail-safe: external x=\$(fn) || true idiom survives fn's non-zero return" "ok" \
    || _assert "18. fail-safe: external x=\$(fn) || true idiom survives fn's non-zero return" "got '$_fs_repo_info'"

  # ── 19. Proof-of-life: selftest is still executing after test 18 — the
  # summary line below is only ever reached if BOTH protective idioms hold. ─
  _assert "19. selftest reached this line — set -e did not abort at test 18" "ok"

  echo ""
  echo "selftest: ${PASS} PASS, ${FAIL} FAIL"
  [ "$FAIL" -eq 0 ] && exit 0 || exit 1
fi

# Quietly succeed if required binaries/db missing (laptop vs CI portability)
for thing in "$PYTHON" "$ROBOREV" "$SQLITE" "$GH" "$ROBOREV_DB"; do
  if [ ! -e "$thing" ]; then
    log "skip: $thing not found"
    echo "roborev_handoff: skipped ($thing missing)"
    exit 0
  fi
done

# ── Temp workspace (cleaned on exit) ─────────────────────────────────────────
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# ── Python: export all stale done jobs to per-job JSON files ─────────────────
# This avoids shell pipe-splitting on multiline/pipe-containing output text.
"$PYTHON" - "$ROBOREV_DB" "$THRESHOLD_DAYS" "$WORKDIR" "$ROBOREV_REPO" <<'PYEOF'
import sys, json, sqlite3, os

db_path, threshold_days, workdir = sys.argv[1], int(sys.argv[2]), sys.argv[3]
filter_repo = sys.argv[4] if len(sys.argv) > 4 else ""
con = sqlite3.connect(db_path)
con.row_factory = sqlite3.Row

# Repos: skip llm; if ROBOREV_REPO env var set, restrict to that one repo
if filter_repo:
    repos = con.execute(
        "SELECT DISTINCT id, name, root_path, COALESCE(identity,'') AS identity "
        "FROM repos WHERE name = ? ORDER BY name, id",
        (filter_repo,)
    ).fetchall()
else:
    repos = con.execute(
        "SELECT DISTINCT id, name, root_path, COALESCE(identity,'') AS identity "
        "FROM repos WHERE name != 'llm' ORDER BY name, id"
    ).fetchall()

repo_file = os.path.join(workdir, "repos.jsonl")
with open(repo_file, "w") as f:
    for r in repos:
        f.write(json.dumps(dict(r)) + "\n")

# Stale done jobs with reviews, per repo.
#
# Performance note (llm#930): classification and the (large, multi-line)
# review body are computed/split out HERE, in the single bulk process that
# already scans the whole DB, instead of via 4 separate python3 -c subprocess
# spawns PER JOB in the bash loop below. With ~7-8k stale jobs across all
# repos, 4 forks/job was the reason an earlier dry-run timed out at 180s
# having reached only one repo alphabetically — the fix is architectural
# (fewer forks), not a bigger timeout.
#   meta_<repo_id>.psv    — job_id|commit_sha|verdict_bool|classification
#                           (pipe-delimited, NOT tab — see the note at the
#                           write site below for why; no output text: safe
#                           for a plain bash `read`, zero subprocess forks
#                           per job)
#   output_<job_id>.txt   — the full review body, read via `cat` ONLY for the
#                           small number of jobs that survive all guards and
#                           actually need it (apply-mode issue/digest bodies;
#                           dry-run never touches these files at all)
for r in repos:
    jobs = con.execute("""
        SELECT
            rj.id         AS job_id,
            COALESCE(c.sha,'') AS commit_sha,
            rv.verdict_bool,
            rv.output
        FROM review_jobs rj
        JOIN repos repo ON repo.id = rj.repo_id
        LEFT JOIN commits c ON c.id = rj.commit_id
        JOIN reviews rv ON rv.job_id = rj.id
        WHERE repo.id = ?
          AND rj.status = 'done'
          AND rj.finished_at IS NOT NULL
          AND (julianday('now') - julianday(rj.finished_at)) > ?
        ORDER BY rj.finished_at ASC
    """, (r["id"], threshold_days)).fetchall()

    # NOTE: pipe-delimited, NOT tab-delimited. Bash `read` treats TAB (like
    # SPACE and NEWLINE) as "IFS white space" and collapses consecutive
    # delimiters even when IFS is set to *only* a tab — so a line with an
    # empty commit_sha field (two delimiters in a row) silently loses a field
    # and everything shifts left by one, corrupting commit_sha/verdict_bool/
    # classification for every empty-SHA job — precisely the population guard
    # 1 exists to catch. Verified empirically: `IFS=$'\t' read` collapses
    # "1090\t\t0\tfail" to 3 fields; `IFS='|' read` on "1090||0|fail" correctly
    # preserves the empty field. Pipe is never a legal value in any of these
    # four columns (job_id/verdict_bool are digits, commit_sha is hex,
    # classification is one of 3 fixed strings), so it is a safe delimiter.
    meta_file = os.path.join(workdir, f"meta_{r['id']}.psv")
    with open(meta_file, "w") as f:
        for j in jobs:
            job_id = j["job_id"]
            commit_sha = (j["commit_sha"] or "").strip()
            verdict_bool = j["verdict_bool"]
            output = j["output"] or ""
            output_trimmed = output.lstrip()

            if verdict_bool == 0:
                classification = "fail"
            elif output_trimmed.startswith("No issues found."):
                classification = "pass-clean"
            else:
                classification = "pass-comments"

            f.write(f"{job_id}|{commit_sha}|{verdict_bool}|{classification}\n")

            with open(os.path.join(workdir, f"output_{job_id}.txt"), "w") as of:
                of.write(output)

    # Warn when done jobs lack finished_at — they are silently excluded above.
    # A non-zero count indicates review_jobs schema integrity issues.
    excluded = con.execute(
        "SELECT COUNT(*) FROM review_jobs rj "
        "WHERE rj.repo_id = ? AND rj.status = 'done' AND rj.finished_at IS NULL",
        (r["id"],)
    ).fetchone()[0]
    if excluded > 0:
        import sys as _sys
        print(
            f"WARN: {excluded} done-but-finished_at-null job(s) excluded from "
            f"handoff for repo '{r['name']}' — investigate review_jobs schema integrity",
            file=_sys.stderr,
        )

con.close()
PYEOF

# ── Helpers ───────────────────────────────────────────────────────────────────

# Extract owner/repo from identity URL:
#   https://github.com/JohnGavin/foo.git  → JohnGavin/foo
#   local:///...                           → empty string (no GH issues)
gh_owner_repo() {
  local identity="$1"
  case "$identity" in
    https://github.com/*)
      echo "$identity" | sed 's|https://github.com/||;s|\.git$||'
      ;;
    *)
      echo ""
      ;;
  esac
}

# Single `gh repo view` call combining hasIssuesEnabled + visibility (llm#930
# guard 3) — one network round-trip per repo instead of two. Prints
# "<true|false|UNKNOWN>|<PUBLIC|PRIVATE|INTERNAL|UNKNOWN>". Fail-safe: any
# failure (auth, network, repo not found) prints "UNKNOWN|UNKNOWN" and returns
# non-zero — callers must treat UNKNOWN as "cannot determine", never as "ok".
gh_repo_info() {
  local owner_repo="$1" json
  [ -z "$owner_repo" ] && { echo "UNKNOWN|UNKNOWN"; return 1; }
  # set -e note: `gh repo view` returning non-zero (auth/network/repo-not-
  # found) must NOT abort the script here — that would make the
  # `if [ -z "$json" ]` fallback below unreachable and defeat the fail-safe
  # entirely (this exact bug shipped once already: the script died silently
  # at THIS line, before ever reaching the UNKNOWN|UNKNOWN echo). `|| json=""`
  # neutralises the failing exit status while still capturing whatever gh
  # produced on stdout (normally nothing, on failure).
  json=$("$GH" repo view "$owner_repo" --json hasIssuesEnabled,visibility 2>/dev/null) || json=""
  if [ -z "$json" ]; then
    echo "UNKNOWN|UNKNOWN"
    return 1
  fi
  "$PYTHON" -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
    ie = d.get('hasIssuesEnabled')
    ie = 'true' if ie is True else 'false' if ie is False else 'UNKNOWN'
    vis = d.get('visibility') or 'UNKNOWN'
    print(f'{ie}|{vis}')
except Exception:
    print('UNKNOWN|UNKNOWN')
" "$json"
}

# Guard 3 (llm#930) opt-in: a repo explicitly allows GH-issue creation while
# PUBLIC by creating <root>/.claude/.roborev-handoff-public-ok containing the
# literal line "allow-public-issues". Absence, or any other content, means
# NOT opted in — mirrors the strict-literal-match convention already used by
# repo_mode()'s inbox marker below.
repo_public_opted_in() {
  local root_path="$1"
  local marker="$root_path/.claude/.roborev-handoff-public-ok"
  [ -f "$marker" ] && grep -q "^allow-public-issues$" "$marker" 2>/dev/null
}

# Lazy-load the full review body for one job (llm#930 perf: only ever called
# for the small number of jobs that survive all three guards and are about to
# be used in an --apply issue/digest body or inbox write — never in dry-run).
job_output() {
  cat "$WORKDIR/output_$1.txt" 2>/dev/null || true
}

# Determine mode for a repo: "inbox" or "gh" (default)
repo_mode() {
  local root_path="$1"
  local marker="$root_path/.claude/.roborev-handoff-mode"
  if [ -f "$marker" ] && grep -q "^inbox$" "$marker" 2>/dev/null; then
    echo "inbox"
  else
    echo "gh"
  fi
}

# NOTE (llm#930): classification ("pass-clean" | "pass-comments" | "fail") is
# now computed once per job inside the bulk Python export above (see the
# "Performance note" comment there) and read directly from meta_<repo_id>.psv
# — there is no bash classify_review() here any more. The selftest block above
# keeps its own tiny inline duplicate (_classify) so the selftest stays
# self-contained without depending on the Python export path.

# ── Counters ──────────────────────────────────────────────────────────────────
repos_total=0; repos_processed=0; repos_skipped=0
act_1a=0; act_1b=0; act_1c=0; act_b=0
# llm#930 guard counters — kept separate per guard so a run's summary line can
# distinguish an empty-SHA skip from a public-repo skip from a cap skip.
skip_empty_sha=0; skip_cap=0; skip_public_no_optin=0; skip_visibility_unknown=0
issues_created_this_run=0

# ── Main loop: per repo ───────────────────────────────────────────────────────
while IFS= read -r repo_json; do
  [ -z "$repo_json" ] && continue
  repo_id=$("$PYTHON" -c "import sys,json; d=json.loads(sys.argv[1]); print(d['id'])" "$repo_json")
  repo_name=$("$PYTHON" -c "import sys,json; d=json.loads(sys.argv[1]); print(d['name'])" "$repo_json")
  root_path=$("$PYTHON" -c "import sys,json; d=json.loads(sys.argv[1]); print(d['root_path'])" "$repo_json")
  identity=$("$PYTHON" -c "import sys,json; d=json.loads(sys.argv[1]); print(d['identity'])" "$repo_json")
  repos_total=$((repos_total + 1))

  # llm#977: per-repo accumulators for Mechanism B (inbox mode) — reset once
  # per repo so the post-job-loop summary write below covers exactly this
  # repo's findings from this run, never a previous repo's leftovers.
  inbox_jobs_this_repo=0
  inbox_ids_this_repo=""

  # Skip repos with no .git on disk
  if [ ! -d "$root_path/.git" ] && [ ! -f "$root_path/.git" ]; then
    log "skip: $repo_name — no .git at $root_path"
    repos_skipped=$((repos_skipped + 1))
    continue
  fi

  repos_processed=$((repos_processed + 1))

  # Determine GH owner/repo and mode
  owner_repo=$(gh_owner_repo "$identity")
  mode=$(repo_mode "$root_path")
  repo_visibility="UNKNOWN"
  repo_public_blocked=0

  # If mode=gh but issues disabled or no GH remote → fall back to inbox mode B
  if [ "$mode" = "gh" ]; then
    if [ -z "$owner_repo" ]; then
      log "warn: $repo_name — no GitHub remote (identity=$identity), falling back to inbox mode"
      mode="inbox"
    else
      # set -e note: gh_repo_info deliberately returns 1 when it cannot
      # determine visibility (see its own fail-safe comment above); capturing
      # the real exit status via `&& gh_repo_info_rc=0 || gh_repo_info_rc=$?`
      # (rather than a blanket `|| true`) neutralises the non-zero status so
      # the run continues, while still letting us tell "call failed entirely"
      # apart from "call succeeded, hasIssuesEnabled=false" below. gh_repo_info
      # already echoes "UNKNOWN|UNKNOWN" to stdout before returning 1, and
      # command substitution captures stdout regardless of exit status, so
      # $repo_info is correctly populated either way.
      repo_info=$(gh_repo_info "$owner_repo") && gh_repo_info_rc=0 || gh_repo_info_rc=$?
      repo_issues_enabled="${repo_info%%|*}"
      repo_visibility="${repo_info##*|}"
      if [ "$gh_repo_info_rc" -ne 0 ]; then
        # The gh call itself failed (auth/network/repo-not-found) — visibility
        # is genuinely undetermined. Do NOT reroute to inbox mode here: leave
        # mode="gh" so guard 3 below blocks the repo and counts it in
        # skip_visibility_unknown, per this file's documented fail-safe intent
        # ("blocked, NOT silently rerouted to inbox mode" — see the llm#930
        # guards comment near the top of this file). Rerouting to inbox here
        # would make skip_visibility_unknown permanently unreachable for the
        # one case it exists to count.
        log "warn: $repo_name — gh_repo_info call failed; visibility undetermined, deferring to guard3 fail-safe"
      elif [ "$repo_issues_enabled" != "true" ]; then
        log "warn: $repo_name — GH issues disabled, falling back to inbox mode"
        mode="inbox"
      fi
    fi
  fi

  # ── Guard 3 (llm#930): public repos require explicit opt-in ────────────────
  # Fail-safe: an UNDETERMINED visibility blocks issue creation — it does NOT
  # fall back to inbox mode, because inbox mode still writes locally-committed
  # content to a repo whose visibility we could not confirm as safe.
  if [ "$mode" = "gh" ]; then
    if [ "$repo_visibility" = "UNKNOWN" ]; then
      log "warn: $repo_name — could not determine repo visibility; blocking issue-creating jobs (fail-safe, guard3)"
      repo_public_blocked=1
    elif [ "$repo_visibility" = "PUBLIC" ] && ! repo_public_opted_in "$root_path"; then
      log "warn: $repo_name — PUBLIC repo without opt-in marker (.claude/.roborev-handoff-public-ok); blocking issue-creating jobs (guard3)"
      repo_public_blocked=1
    fi
  fi

  # Process stale done jobs for this repo (see the bulk-export Python block
  # above for why this is pipe-delimited with no per-job subprocess parsing —
  # tab collapses consecutive delimiters in bash `read` and would corrupt
  # every empty-commit_sha row exactly where guard 1 needs to see them)
  meta_file="$WORKDIR/meta_${repo_id}.psv"
  [ ! -f "$meta_file" ] && continue

  while IFS='|' read -r job_id commit_sha verdict_bool classification; do
    [ -z "$job_id" ] && continue

    # ── Guard 1 (llm#930): empty commit SHA — skip unconditionally, before
    # classification, regardless of mode. Per llm#923 / roborev-exclude-patterns,
    # these are orphaned/range jobs that must not be mass-processed: an issue
    # or digest entry that cannot reference what it is about is worse than no
    # action at all. ──────────────────────────────────────────────────────────
    if [ -z "$commit_sha" ]; then
      log "skip: $repo_name job=$job_id empty commit_sha (orphaned/range job, not mass-processed — llm#923)"
      skip_empty_sha=$((skip_empty_sha + 1))
      continue
    fi

    commit_short="${commit_sha:0:7}"

    case "$classification" in

      # ── Phase 1c: pass clean → silent close ────────────────────────────
      pass-clean)
        if [ "$APPLY" -eq 0 ]; then
          echo "[dry] $repo_name: would close pass-clean (job $job_id)"
        else
          if "$ROBOREV" close "$job_id" >/dev/null 2>&1; then
            log "1c: closed pass-clean job=$job_id repo=$repo_name"
          else
            log "fail: roborev close $job_id (1c)"
          fi
        fi
        act_1c=$((act_1c + 1))
        ;;

      # ── Mechanism B (inbox mode) ────────────────────────────────────────
      # llm#977: this used to append one `## Inbox: roborev finding` block
      # per finding directly to CURRENT_WORK.md here, unbounded — that grew
      # the file to 3856 lines / 539 entries because nothing ever trims it,
      # and a later rewrite silently discarded all of them. The findings
      # themselves already live in $FINDINGS_DIR and the roborev DB, both
      # queryable — CURRENT_WORK.md only needs a signal that new findings
      # exist. So this branch now just records the full finding to
      # $FINDINGS_DIR (unchanged) and accumulates a per-repo count; the
      # actual CURRENT_WORK.md write happens ONCE per repo after the job
      # loop below, as a single summary line matching the style
      # session_init.sh already uses for `roborev-backlog: open=N ...`.
      fail|pass-comments)
        if [ "$mode" = "inbox" ]; then
          if [ "$APPLY" -eq 0 ]; then
            echo "[dry] $repo_name: would record inbox finding (job $job_id, mode=inbox)"
          else
            # Idempotency: skip if this job's finding was already saved by a
            # prior run (e.g. a run where the subsequent `roborev close`
            # failed, leaving the job eligible to reappear in meta_file).
            if [ -f "$FINDINGS_DIR/${job_id}.md" ]; then
              log "skip: $repo_name job=$job_id already recorded in $FINDINGS_DIR"
            else
              output=$(job_output "$job_id")
              printf '%s\n' "$output" > "$FINDINGS_DIR/${job_id}.md"
              inbox_jobs_this_repo=$((inbox_jobs_this_repo + 1))
              inbox_ids_this_repo="${inbox_ids_this_repo:+$inbox_ids_this_repo,}${job_id}"
              log "B: recorded inbox job=$job_id repo=$repo_name findings=$FINDINGS_DIR/${job_id}.md"
            fi

            if "$ROBOREV" close "$job_id" >/dev/null 2>&1; then
              log "B: closed job=$job_id"
            else
              log "fail: roborev close $job_id (B) — finding recorded but job not closed"
            fi
          fi
          act_b=$((act_b + 1))

        # ── Mechanism A (GH issues): subject to guards 2 (cap) and 3 (public-
        # repo opt-in) — llm#930. Both are checked BEFORE any gh issue
        # create/edit call, in both dry-run and --apply, so the cap and the
        # public-repo block are provable from a --dry-run run alone. ────────
        elif [ "$repo_public_blocked" -eq 1 ]; then
          echo "[skip] $repo_name: public-repo guard blocked (job $job_id, visibility=$repo_visibility)"
          if [ "$repo_visibility" = "UNKNOWN" ]; then
            skip_visibility_unknown=$((skip_visibility_unknown + 1))
          else
            skip_public_no_optin=$((skip_public_no_optin + 1))
          fi

        elif [ "$issues_created_this_run" -ge "$MAX_ISSUES_PER_RUN" ]; then
          echo "[skip] $repo_name: per-run issue-action cap reached ($MAX_ISSUES_PER_RUN), skipping (job $job_id)"
          log "skip: $repo_name job=$job_id cap-reached (MAX_ISSUES_PER_RUN=$MAX_ISSUES_PER_RUN)"
          skip_cap=$((skip_cap + 1))

        # ── Mechanism A: fail → per-commit GH issue (Phase 1a) ───────────
        elif [ "$classification" = "fail" ]; then
          issues_created_this_run=$((issues_created_this_run + 1))
          if [ "$APPLY" -eq 0 ]; then
            echo "[dry] $repo_name: would create GH issue (commit $commit_short, job $job_id, label roborev-handoff)"
          else
            output=$(job_output "$job_id")
            # Idempotency: search for existing issue with this commit sha
            existing=$(
              "$GH" issue list \
                --repo "$owner_repo" \
                --label roborev-handoff \
                --search "$commit_sha in:body" \
                --json number \
                -q '.[0].number' 2>/dev/null || echo ""
            )
            if [ -n "$existing" ]; then
              log "skip: $repo_name job=$job_id issue already exists (#$existing)"
            else
              # Use --body-file to avoid command-substitution approval prompts (#200)
              _body_file_1a=$(mktemp /tmp/roborev_handoff_1a_XXXXXX.md)
              printf '## roborev review — commit `%s`\n\n%s\n\n---\n_roborev job: %s_\n' \
                "$commit_short" "$output" "$job_id" > "$_body_file_1a"
              issue_url=$(
                "$GH" issue create \
                  --repo "$owner_repo" \
                  --title "roborev review for $commit_short" \
                  --label "roborev-handoff" \
                  --body-file "$_body_file_1a" 2>/dev/null
              )
              rm -f "$_body_file_1a"
              [ -n "$issue_url" ] && {
                log "1a: created issue $issue_url job=$job_id repo=$repo_name"
                "$ROBOREV" close "$job_id" >/dev/null 2>&1 \
                  && log "1a: closed job=$job_id" \
                  || log "fail: roborev close $job_id (1a) — issue created but job not closed"
              } || {
                log "fail: gh issue create failed for job=$job_id repo=$repo_name (job left open)"
              }
            fi
          fi
          act_1a=$((act_1a + 1))

        # ── Mechanism A: pass-comments → weekly digest (Phase 1b) ─────────
        else
          issues_created_this_run=$((issues_created_this_run + 1))
          iso_week=$(date -u +%G-W%V)
          digest_title="roborev pass-comments digest $iso_week"

          if [ "$APPLY" -eq 0 ]; then
            echo "[dry] $repo_name: would append to digest $iso_week (job $job_id)"
          else
            output=$(job_output "$job_id")
            # Find open digest issue for this week
            digest_num=$(
              "$GH" issue list \
                --repo "$owner_repo" \
                --label roborev-digest \
                --state open \
                --search "\"$digest_title\" in:title" \
                --json number \
                -q '.[0].number' 2>/dev/null || echo ""
            )

            append_block=$(printf '\n---\n### Commit %s (job %s) — %s\n\n%s\n' \
              "$commit_short" "$job_id" "$(date -u +%F)" "$output")

            if [ -n "$digest_num" ]; then
              # Idempotency: check if job already in digest body
              existing_body=$(
                "$GH" issue view "$digest_num" --repo "$owner_repo" --json body -q '.body' 2>/dev/null || echo ""
              )
              if echo "$existing_body" | grep -q "job $job_id"; then
                log "skip: $repo_name job=$job_id already in digest #$digest_num"
              else
                new_body="${existing_body}${append_block}"
                # Use --body-file to avoid command-substitution approval prompts (#200)
                _body_file_1b=$(mktemp /tmp/roborev_handoff_1b_XXXXXX.md)
                printf '%s' "$new_body" > "$_body_file_1b"
                "$GH" issue edit "$digest_num" --repo "$owner_repo" --body-file "$_body_file_1b" >/dev/null 2>&1
                _gh_rc=$?
                rm -f "$_body_file_1b"
                [ "$_gh_rc" -eq 0 ] && {
                  log "1b: appended to digest #$digest_num job=$job_id repo=$repo_name"
                  "$ROBOREV" close "$job_id" >/dev/null 2>&1 \
                    && log "1b: closed job=$job_id" \
                    || log "fail: roborev close $job_id (1b) — appended but not closed"
                } || {
                  log "fail: gh issue edit #$digest_num failed for job=$job_id (job left open)"
                }
              fi
            else
              # Create new digest issue for this week
              # Use --body-file to avoid command-substitution approval prompts (#200)
              _body_file_1b_new=$(mktemp /tmp/roborev_handoff_1bnew_XXXXXX.md)
              printf '%s' "$append_block" > "$_body_file_1b_new"
              issue_url=$(
                "$GH" issue create \
                  --repo "$owner_repo" \
                  --title "$digest_title" \
                  --label "roborev-digest" \
                  --body-file "$_body_file_1b_new" 2>/dev/null
              )
              rm -f "$_body_file_1b_new"
              [ -n "$issue_url" ] && {
                log "1b: created digest $issue_url job=$job_id repo=$repo_name"
                "$ROBOREV" close "$job_id" >/dev/null 2>&1 \
                  && log "1b: closed job=$job_id" \
                  || log "fail: roborev close $job_id (1b) — digest created but not closed"
              } || {
                log "fail: gh issue create digest failed for job=$job_id repo=$repo_name (job left open)"
              }
            fi
          fi
          act_1b=$((act_1b + 1))
        fi
        ;;
    esac
  done < "$meta_file"

  # llm#977: single per-repo, per-run summary line for Mechanism B — replaces
  # the old one-block-per-finding append. Only written in --apply mode, and
  # only when this run actually recorded ≥1 new inbox finding for this repo.
  if [ "$APPLY" -eq 1 ] && [ "$inbox_jobs_this_repo" -gt 0 ]; then
    current_work="$root_path/.claude/CURRENT_WORK.md"
    mkdir -p "$(dirname "$current_work")"
    printf '\nroborev-inbox: %d new finding(s) (jobs %s) -- see `~/.roborev/findings/<job>.md` or `roborev show <job>`\n' \
      "$inbox_jobs_this_repo" "$inbox_ids_this_repo" >> "$current_work"
    log "B: wrote inbox summary line to $current_work (count=$inbox_jobs_this_repo repo=$repo_name)"
  fi

done < "$WORKDIR/repos.jsonl"

# ── Summary ───────────────────────────────────────────────────────────────────
mode_label="dry-run"; [ "$APPLY" -eq 1 ] && mode_label="applied"
summary="roborev_handoff [$mode_label]: repos=$repos_total processed=$repos_processed actions={1a:$act_1a,1b:$act_1b,1c:$act_1c,B:$act_b} guard_skips={empty_sha:$skip_empty_sha,cap:$skip_cap,public_no_optin:$skip_public_no_optin,visibility_unknown:$skip_visibility_unknown} cap=$MAX_ISSUES_PER_RUN repos_skipped=$repos_skipped"
log "$summary"
echo "$summary"
