#!/usr/bin/env bash
# roborev_requeue_dropped.sh — find roborev review jobs that died on an
# agent quota/spend-limit error and were never successfully retried, and
# re-enqueue a small, rate-limited batch of them.
#
# Why this exists (llm#927): roborev's internal retry logic gives up after
# retry_count reaches its cap and marks the job status='failed' — a TERMINAL
# state. Nothing in roborev, and nothing in our own automation
# (roborev_poll_merges.sh looks for *unreviewed commits since a ref*, not
# *failed jobs to retry*), ever revisits that commit once the agent's quota
# resets. The work is DROPPED, not deferred. Measured 2026-08-14 on the real
# DB: dozens of commits sit in exactly this state.
#
# THE TRAP (read before changing the filtering logic below): a large
# majority of these dropped commits are in llmtelemetry, a ~400-commits/week
# AUTOMATED-DATA repo that already carries a `.roborev.toml` excluding
# inst/extdata/** and vignettes/data/** — precisely because reviewing
# regenerated data produced 234 findings in 7 days at a 16.7% close rate,
# none of them real bugs (see roborev-exclude-patterns-details.md's
# "Case study — llmtelemetry"). A naive sweep would faithfully re-enqueue
# every one of those bot-data commits on its first run and re-automate the
# exact noise that exclude_patterns exists to remove — while burning agent
# quota to do it. So every candidate is checked against its OWN repo's
# `.roborev.toml` exclude_patterns before being enqueued: if every file the
# commit touches matches an exclude pattern, it is skipped, not enqueued.
# If we cannot determine this reliably (repo checkout missing locally, git
# fails, no files reported) we ALSO skip and report — a false skip costs one
# still-unreviewed commit; a false enqueue costs quota, noise, and trust in
# the tool. See the dispatch's THE TRAP note and llm#198/llmtelemetry
# 2026-07-22 case study for the full incident this mirrors.
#
# Candidate definition:
#   For each (repo_id, commit_id) pair, look at its MOST RECENT review_jobs
#   row (by enqueued_at, tie-break id — see "Latest-job-wins" below). That
#   row must have status='failed', commit_id IS NOT NULL (single-commit
#   `review` jobs only — range/compact job_types are out of scope, see
#   "Scope" below), and error text matching a verified quota/spend pattern
#   (see QUOTA_ERROR_SQL — strings taken from an actual query against
#   ~/.roborev/reviews.db on 2026-08-14, not guessed). The pair must ALSO
#   have no row (any status, any age) with status IN ('done','applied',
#   'rebased') (successful outcomes broader than just 'done' — a job that
#   got applied or rebased was reviewed) and no row with status IN
#   ('queued','running') (already in flight — re-enqueueing would duplicate
#   it; this is the idempotency check required by requirement 5).
#
# Latest-job-wins (llm#964): earlier versions of this script matched ANY
# failed+quota row, so a pair that failed on quota once and then failed
# again on a DIFFERENT terminal error on every subsequent requeue (e.g. a
# revoked API key producing HTTP 401) was selected forever — the original
# quota row never left the result set. Verified on the real DB 2026-08-14:
# repo coMMpass (repo_id=3), commit 0e787dfe... — job 261 failed on a
# genuine quota error 2026-03-24; four later requeues (12469/12478/12485/
# 12491) each failed with "401 Unauthorized: Incorrect API key", yet the
# pair was still being re-selected on every run because job 261 still
# matched. Checking only the LATEST job per pair fixes this: once the
# latest attempt fails for a non-quota reason, the pair stops being
# offered — retrying further cannot help until something about the error
# itself changes, which a human/other automation must address separately.
#
# Scope: only job_type='review' jobs with a populated commit_id are
# considered. review_jobs.diff_content/dirty_files are NOT populated for
# these rows (verified against the real DB), so there is no way to inspect
# the failed job's diff without a local checkout — hence the repo-
# availability check below. range/compact job_types (git_ref is a SHA..SHA
# span, not a single commit) are a materially different re-enqueue shape
# (which sub-range failed?) and are left for a follow-up rather than
# guessed at here.
#
# Usage:
#   roborev_requeue_dropped.sh                 # dry-run (default)
#   roborev_requeue_dropped.sh --dry-run
#   roborev_requeue_dropped.sh --apply          # enqueue up to --limit jobs
#   roborev_requeue_dropped.sh --apply --limit=3
#   roborev_requeue_dropped.sh --selftest       # fixture-based test suite
#
# Rate limit: --limit=N (default 5). The failure this script fixes IS quota
# exhaustion — enqueueing a burst of retries the instant the sweep runs
# would just recreate the same exhaustion. N bounds every single invocation,
# --dry-run or --apply alike (dry-run still stops listing new candidates as
# "would enqueue" past the limit, so the printed preview matches what --apply
# would actually do).
#
# Reported "actionable" count (llm#966): raw `candidates` includes pairs
# this sweep can never enqueue — excluded-path-only commits and commits
# whose repo checkout is gone from disk are permanently un-enqueueable, not
# merely waiting their turn. Reporting `candidates` alone overstates the
# real backlog by exactly those pairs. `actionable = candidates -
# skipped_excluded - skipped_unavailable` is the size of the backlog this
# sweep can actually work through.
#
# Idempotency: re-running with --apply must never double-enqueue a ref that
# is already queued/running from a prior invocation (or from any other
# roborev caller) — enforced by the `pending` CTE in the candidate query
# below, checked BEFORE any candidate is counted, not just before the
# `roborev review` call.
#
# Housekeeping heartbeat (housekeeping-framework rule): every invocation
# (including a zero-candidate run and --selftest's fixture sub-runs) writes
# a housekeeping_runs row (task='roborev_requeue_dropped') via the same
# hk_run_start/hk_run_end pattern secret_exposure_scan.sh established
# (llm#951) — proof the sweep ran matters more than the count it found.
# Target DB: ~/.claude/logs/unified.duckdb (override via UNIFIED_DB_PATH,
# used by --selftest to never touch the real DB).
#
# Scheduling: this script is NOT wired into a launchd plist yet. Per the
# dispatch's "schedule from an existing slot" instruction, the recommended
# slot is `com.claude.roborev-poll-merges` (fires thrice daily, Mon–Fri
# 09:00/13:00/17:00) — it already does roborev catch-up enqueueing on a
# schedule, already exports the same PATH/codex-shim/CLAUDE_TRIGGER
# environment this script needs, and already treats "coverage gap" as its
# job. Wiring requires appending a call to roborev_poll_merges.sh (or its
# plist's ProgramArguments), which is outside this dispatch's write-paths
# scope (only this script + roborev-resolution.md + its companions) — left
# for a follow-up commit. See the roborev-resolution.md "Requeue Dropped
# Quota Failures" section for the actual command line to add.
#
# Exit codes:
#   0 ok (including "nothing to do" and "roborev/sqlite/git missing")
#   1 unexpected error (selftest failure only — the sweep itself never
#     fails the process for per-candidate problems, matching
#     roborev_poll_merges.sh's fail-open posture)

set -uo pipefail
# Deliberately NOT `set -e` — one candidate's git/sqlite hiccup must never
# abort the rest of the sweep (same rationale as secret_exposure_scan.sh).

# Portability: launchd provides only a bare PATH. Prepend coreutils paths so
# git/sqlite3/roborev/duckdb resolve on both Homebrew and Nix Macs (mirrors
# roborev_poll_merges.sh).
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
# Wire codex_with_fallback.sh into roborev's codex calls (#365), same as
# roborev_poll_merges.sh — a re-enqueued job may fall back to codex.
if [ -n "${_SCRIPT_DIR:-}" ] && [ -x "${_SCRIPT_DIR}/codex_shim/codex" ]; then
  export PATH="${_SCRIPT_DIR}/codex_shim:$PATH"
fi
# Mark session as scheduled/automated for llmtelemetry_emit.sh (#322 Phase 2).
export CLAUDE_TRIGGER="${CLAUDE_TRIGGER:-scheduled}"

HOME_DIR="${HOME:-/Users/johngavin}"
DB="${ROBOREV_DB:-$HOME_DIR/.roborev/reviews.db}"
SQLITE="${SQLITE:-/usr/bin/sqlite3}"
ROBOREV="${ROBOREV:-/usr/local/bin/roborev}"
GIT_BIN="${GIT_BIN:-/usr/bin/git}"
UNIFIED_DB="${UNIFIED_DB_PATH:-${HOME_DIR}/.claude/logs/unified.duckdb}"
LOG_FILE="${LOG_FILE_PATH:-${HOME_DIR}/.claude/logs/roborev_requeue_dropped.log}"

log() {
  { mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"
  } 2>/dev/null || true
}

# Verified quota/spend error substrings — taken from an actual DISTINCT
# query against review_jobs.error on the real ~/.roborev/reviews.db,
# 2026-08-14 (not guessed): "You've hit your limit", "...monthly spend
# limit...", "...org's monthly usage limit", "...session limit...",
# "Quota exceeded", "codex ... You've hit your usage limit", plus a
# "quota:" prefix roborev itself sometimes adds. SQLite LIKE is
# case-insensitive for ASCII by default, so no separate-case variants
# needed. 'rate limit' is included for forward-compatibility (agents whose
# error text uses that phrasing) even though it matched 0 rows on
# 2026-08-14.
QUOTA_ERROR_SQL="(error LIKE '%spend limit%' OR error LIKE '%quota%' OR error LIKE '%usage limit%' OR error LIKE '%hit your limit%' OR error LIKE '%session limit%' OR error LIKE '%rate limit%')"

MODE="dry-run"
LIMIT=5
for arg in "$@"; do
  case "$arg" in
    --apply) MODE="apply" ;;
    --dry-run) MODE="dry-run" ;;
    --limit=*) LIMIT="${arg#--limit=}" ;;
    --selftest) MODE="selftest" ;;
    -h|--help)
      sed -n '2,70p' "$0"
      exit 0
      ;;
    *)
      echo "roborev_requeue_dropped: unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done
case "$LIMIT" in
  ''|*[!0-9]*)
    echo "roborev_requeue_dropped: --limit must be a non-negative integer, got '$LIMIT'" >&2
    exit 2
    ;;
esac

# ---------------------------------------------------------------------------
# Housekeeping heartbeat (llm#951 pattern, established by
# secret_exposure_scan.sh — see that script's header for the full rationale;
# this is the same four functions, task name changed).
# ---------------------------------------------------------------------------

_duckdb_ok=0
if command -v duckdb >/dev/null 2>&1 && [ -f "$UNIFIED_DB" ]; then
  _duckdb_ok=1
fi
_run_id=""
_run_started=""

hk_run_start() {
  [ "$_duckdb_ok" = "1" ] || return 0
  _run_id="$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  [ -n "$_run_id" ] || return 0
  _run_started="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  duckdb -init /dev/null "$UNIFIED_DB" -c "
    INSERT OR IGNORE INTO housekeeping_runs
      (id, task, source_script, started_at, status, rows_written)
    VALUES (
      '${_run_id}',
      'roborev_requeue_dropped',
      '${_SCRIPT_DIR}/roborev_requeue_dropped.sh',
      TIMESTAMPTZ '${_run_started}',
      'ok',
      0
    );
  " >/dev/null 2>&1 || true
}

hk_run_end() {
  [ "$_duckdb_ok" = "1" ] || return 0
  [ -n "$_run_id" ] || return 0
  local status="$1" rows="${2:-0}" detail="${3:-}" ended
  ended="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  local detail_sql="NULL"
  if [ -n "$detail" ]; then
    local detail_escaped="${detail//\'/\'\'}"
    detail_sql="'${detail_escaped}'"
  fi
  duckdb -init /dev/null "$UNIFIED_DB" -c "
    UPDATE housekeeping_runs
    SET ended_at = TIMESTAMPTZ '${ended}',
        status = '${status}',
        rows_written = ${rows},
        detail_json = ${detail_sql}
    WHERE id = '${_run_id}';
  " >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# get_exclude_patterns ROOT_PATH — print one exclude glob per line, scoped
# to the exclude_patterns = [ ... ] array in ROOT_PATH/.roborev.toml. Empty
# output (no lines) if the file/array is absent — the caller then treats the
# commit as having nothing to exclude against, i.e. eligible (this is a
# deliberate choice for repos never configured with exclude_patterns; it
# does NOT re-open the llmtelemetry-shaped trap because llmtelemetry HAS an
# exclude_patterns block and is exactly where the filter fires).
get_exclude_patterns() {
  local toml="$1/.roborev.toml"
  [ -f "$toml" ] || return 0
  awk '
    /^[[:space:]]*exclude_patterns[[:space:]]*=[[:space:]]*\[/ { inarr=1 }
    inarr { print }
    inarr && /\]/ { inarr=0 }
  ' "$toml" 2>/dev/null | grep -oE '"[^"]*"' | sed -e 's/^"//' -e 's/"$//'
}

# file_is_excluded FILE PATTERN... — true if FILE matches any PATTERN.
# `case` pattern matching in bash is not filesystem globbing: `*` freely
# matches `/`, so a TOML pattern like "inst/extdata/**" works verbatim as a
# case pattern with no translation needed (the extra `*` is redundant but
# harmless — case doesn't give "**" special recursive meaning, it's just
# more wildcard).
file_is_excluded() {
  local f="$1"; shift
  local pat
  for pat in "$@"; do
    case "$f" in
      $pat) return 0 ;;
    esac
  done
  return 1
}

# commit_excluded ROOT_PATH SHA PATTERN... — echoes one of:
#   eligible            — at least one changed file is not excluded
#   excluded            — every changed file matches an exclude pattern
#   repo_unavailable    — ROOT_PATH has no local .git (cannot determine)
#   git_failed          — `git show` failed (cannot determine)
#   no_files_reported   — git succeeded but reported zero changed files
#     (defensive: treat as "cannot determine" rather than assume eligible)
# Per the dispatch brief: when we cannot determine reliably, the caller
# skips rather than enqueues.
commit_excluded() {
  local root_path="$1" sha="$2"; shift 2
  local -a patterns=("$@")

  if [ ! -d "$root_path/.git" ] && [ ! -f "$root_path/.git" ]; then
    echo "repo_unavailable"
    return
  fi

  # Capture git show's OWN exit status via PIPESTATUS, not the pipeline's
  # (which under `pipefail` reports the rightmost non-zero command — grep
  # exits 1 on "no matching lines", which would otherwise mask a genuine
  # git failure such as "bad object" as a misleading "no_files_reported").
  local files git_status
  files="$("$GIT_BIN" -C "$root_path" show --no-color --name-only --pretty=format: "$sha" 2>/dev/null | grep -v '^[[:space:]]*$')"
  git_status="${PIPESTATUS[0]}"
  if [ "$git_status" -ne 0 ]; then
    echo "git_failed"
    return
  fi
  if [ -z "$files" ]; then
    echo "no_files_reported"
    return
  fi

  # No exclude_patterns configured at all -> nothing to exclude against.
  if [ "${#patterns[@]}" -eq 0 ]; then
    echo "eligible"
    return
  fi

  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if ! file_is_excluded "$f" "${patterns[@]}"; then
      echo "eligible"
      return
    fi
  done <<< "$files"

  echo "excluded"
}

# ---------------------------------------------------------------------------
# Selftest
# ---------------------------------------------------------------------------

run_selftest() {
  local total=0 pass=0

  local tmp_root
  tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/roborev_requeue_selftest.XXXXXX")"
  local fixture_db="${tmp_root}/reviews.db"
  local fake_git_repo="${tmp_root}/repo"
  local fake_roborev="${tmp_root}/fake_roborev.sh"
  local fake_hk_db="${tmp_root}/unified.duckdb"
  local sqlite_bin="${SQLITE}"
  local git_bin="${GIT_BIN}"

  # ---- fixture git repo: one commit touching only an excluded path, one
  # touching real code, one touching both, plus three more real-code
  # commits reserved for the llm#964 latest-job-wins cases (f/h/i below). ----
  mkdir -p "$fake_git_repo"
  "$git_bin" -C "$fake_git_repo" init -q -b main
  "$git_bin" -C "$fake_git_repo" config user.email "test@example.com"
  "$git_bin" -C "$fake_git_repo" config user.name "Test"
  mkdir -p "$fake_git_repo/inst/extdata"
  echo '{"a":1}' > "$fake_git_repo/inst/extdata/data.json"
  "$git_bin" -C "$fake_git_repo" add -A
  "$git_bin" -C "$fake_git_repo" commit -q -m "data: seed"
  local sha_data
  sha_data="$("$git_bin" -C "$fake_git_repo" rev-parse HEAD)"

  echo '{"a":2}' > "$fake_git_repo/inst/extdata/data.json"
  "$git_bin" -C "$fake_git_repo" add -A
  "$git_bin" -C "$fake_git_repo" commit -q -m "data: refresh"
  local sha_data2
  sha_data2="$("$git_bin" -C "$fake_git_repo" rev-parse HEAD)"

  mkdir -p "$fake_git_repo/R"
  echo 'f <- function() 1' > "$fake_git_repo/R/foo.R"
  "$git_bin" -C "$fake_git_repo" add -A
  "$git_bin" -C "$fake_git_repo" commit -q -m "feat: real code"
  local sha_real
  sha_real="$("$git_bin" -C "$fake_git_repo" rev-parse HEAD)"

  # Case (f) fixture commit: proves a non-quota-only failure never becomes
  # a candidate. Deliberately a SEPARATE commit from sha_real above — an
  # earlier version of this fixture reused commit_id=3 (sha_real's own
  # commit row) for this case, which only worked because the OLD code
  # matched ANY failed+quota row for a pair. Under llm#964's
  # latest-job-wins rule that collision would have wrongly killed case (a)
  # too (job 105 would become the pair's "latest" job and it is
  # non-quota), so this is now its own commit.
  echo 'nq <- function() 0' > "$fake_git_repo/R/nonquota.R"
  "$git_bin" -C "$fake_git_repo" add -A
  "$git_bin" -C "$fake_git_repo" commit -q -m "feat: real code (non-quota only)"
  local sha_nonquota
  sha_nonquota="$("$git_bin" -C "$fake_git_repo" rev-parse HEAD)"

  # Case (h) fixture commit (llm#964): earlier quota failure, LATER
  # non-quota failure -> latest job wins, pair must NOT be a candidate.
  # This is the coMMpass shape (job 261 quota-failed 2026-03-24; four later
  # requeues all failed on "401 Unauthorized: Incorrect API key" yet the
  # old query kept re-selecting the pair forever because job 261 still
  # matched the quota pattern).
  echo 'h <- function() 0' > "$fake_git_repo/R/caseh.R"
  "$git_bin" -C "$fake_git_repo" add -A
  "$git_bin" -C "$fake_git_repo" commit -q -m "feat: real code (case h)"
  local sha_h
  sha_h="$("$git_bin" -C "$fake_git_repo" rev-parse HEAD)"

  # Case (i) fixture commit (llm#964): earlier non-quota failure, LATER
  # quota failure -> latest job wins the OTHER direction too: pair MUST
  # remain a candidate. Proves the rule looks at the latest job, not "any
  # quota row ever" and not "any non-quota row ever".
  echo 'i <- function() 0' > "$fake_git_repo/R/casei.R"
  "$git_bin" -C "$fake_git_repo" add -A
  "$git_bin" -C "$fake_git_repo" commit -q -m "feat: real code (case i)"
  local sha_i
  sha_i="$("$git_bin" -C "$fake_git_repo" rev-parse HEAD)"

  cat > "$fake_git_repo/.roborev.toml" <<'EOF'
exclude_patterns = [
  "inst/extdata/**",
]
EOF

  # A repo id whose root_path does not exist on disk -> repo_unavailable.
  local missing_repo="${tmp_root}/does-not-exist"

  # ---- fixture sqlite DB mimicking review_jobs/repos/commits ----
  "$sqlite_bin" "$fixture_db" <<SQL
CREATE TABLE repos (id INTEGER PRIMARY KEY, root_path TEXT UNIQUE NOT NULL, name TEXT NOT NULL);
CREATE TABLE commits (id INTEGER PRIMARY KEY, repo_id INTEGER NOT NULL, sha TEXT NOT NULL, subject TEXT NOT NULL);
CREATE TABLE review_jobs (
  id INTEGER PRIMARY KEY,
  repo_id INTEGER NOT NULL,
  commit_id INTEGER,
  git_ref TEXT NOT NULL,
  status TEXT NOT NULL,
  error TEXT,
  enqueued_at TEXT NOT NULL DEFAULT '2026-01-01 00:00:00'
);

INSERT INTO repos VALUES (1, '${fake_git_repo}', 'fixture-repo');
INSERT INTO repos VALUES (2, '${missing_repo}', 'missing-repo');

INSERT INTO commits VALUES (1, 1, '${sha_data}',  'data: seed');
INSERT INTO commits VALUES (2, 1, '${sha_data2}', 'data: refresh');
INSERT INTO commits VALUES (3, 1, '${sha_real}',  'feat: real code');
INSERT INTO commits VALUES (4, 2, 'deadbeef',      'commit in a repo whose checkout is gone');
INSERT INTO commits VALUES (5, 1, '${sha_real}2',  'later-succeeded commit placeholder');
INSERT INTO commits VALUES (8, 1, '${sha_nonquota}', 'feat: real code (non-quota only)');
INSERT INTO commits VALUES (9, 1, '${sha_h}', 'feat: real code (case h)');
INSERT INTO commits VALUES (10, 1, '${sha_i}', 'feat: real code (case i)');

-- Case (a): quota-failed, sole job for the pair -> candidate.
INSERT INTO review_jobs VALUES (100, 1, 3, '${sha_real}', 'failed', 'quota: agent: codex failed: exit status 1 (parse error: codex stream reported failure: Quota exceeded. Check your plan.', '2026-01-01 00:00:00');

-- Case (b): quota-failed but a LATER 'done' row exists for the same pair -> NOT a candidate.
INSERT INTO review_jobs VALUES (101, 1, 2, '${sha_data2}', 'failed', 'agent: claude-code failed
stream: stream errors: You''ve hit your monthly spend limit', '2026-01-01 00:01:00');
INSERT INTO review_jobs VALUES (102, 1, 2, '${sha_data2}', 'done', NULL, '2026-01-01 00:02:00');

-- Case (c): candidate whose commit touches ONLY excluded paths -> skipped(excluded).
INSERT INTO review_jobs VALUES (103, 1, 1, '${sha_data}', 'failed', 'agent: claude-code failed
stream: stream errors: You''ve hit your session limit', '2026-01-01 00:03:00');

-- Case: repo_unavailable (checkout missing on disk).
INSERT INTO review_jobs VALUES (104, 2, 4, 'deadbeef', 'failed', 'quota: agent: gemini failed: Quota exceeded.', '2026-01-01 00:04:00');

-- Case (f): non-quota failure, sole job for its own pair -> never a candidate.
INSERT INTO review_jobs VALUES (105, 1, 8, '${sha_nonquota}', 'failed', 'build prompt: get commit info: git log: fork/exec /opt/homebrew/bin/git: resource temporarily unavailable', '2026-01-01 00:05:00');

-- Case (h) — llm#964 latest-job-wins: earlier quota failure, LATER
-- non-quota failure -> latest job is non-quota, pair must NOT be a
-- candidate even though a quota row exists in its history.
INSERT INTO review_jobs VALUES (200, 1, 9, '${sha_h}', 'failed', 'quota: agent: codex failed: Quota exceeded.', '2026-02-01 00:00:00');
INSERT INTO review_jobs VALUES (201, 1, 9, '${sha_h}', 'failed', '401 Unauthorized: Incorrect API key provided', '2026-02-02 00:00:00');

-- Case (i) — llm#964 latest-job-wins, other direction: earlier non-quota
-- failure, LATER quota failure -> latest job is quota, pair MUST remain a
-- candidate.
INSERT INTO review_jobs VALUES (210, 1, 10, '${sha_i}', 'failed', 'build prompt: get commit info: git log: fork/exec /opt/homebrew/bin/git: resource temporarily unavailable', '2026-02-01 00:00:00');
INSERT INTO review_jobs VALUES (211, 1, 10, '${sha_i}', 'failed', 'quota: agent: codex failed: Quota exceeded.', '2026-02-02 00:00:00');
SQL

  # ---- fake `roborev` binary: records invocations, never touches network ----
  cat > "$fake_roborev" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "${FAKE_ROBOREV_LOG:?}"
echo "Enqueued job 9999 for fake"
exit 0
EOF
  chmod +x "$fake_roborev"
  local fake_roborev_log="${tmp_root}/fake_roborev_calls.log"
  : > "$fake_roborev_log"

  duckdb -init /dev/null "$fake_hk_db" < "${_SCRIPT_DIR}/housekeeping_schema_init.sql" >/dev/null 2>&1 || true

  # ---- Check 1: candidate query selects case (a), excludes case (b) ----
  total=$((total + 1))
  local out
  out="$(ROBOREV_DB="$fixture_db" SQLITE="$sqlite_bin" ROBOREV="$fake_roborev" GIT_BIN="$git_bin" \
    UNIFIED_DB_PATH="$fake_hk_db" LOG_FILE_PATH="${tmp_root}/log1.log" FAKE_ROBOREV_LOG="$fake_roborev_log" \
    bash "$0" --dry-run --limit=10 2>&1)"
  if echo "$out" | grep -q "would enqueue.*${sha_real}" && ! echo "$out" | grep -q "would enqueue.*${sha_data2}"; then
    pass=$((pass + 1))
  else
    echo "FAIL: candidate query did not select case (a) / excluded case (b). Output:"
    echo "$out"
  fi

  # ---- Check 2: case (c) is skipped as excluded (bot-data only) ----
  total=$((total + 1))
  if echo "$out" | grep -q "skip.*excluded.*${sha_data}"; then
    pass=$((pass + 1))
  else
    echo "FAIL: case (c) (excluded-paths-only commit) was not reported as skip/excluded. Output:"
    echo "$out"
  fi

  # ---- Check 2b (llm#966): summary line's `actionable` field is honest —
  # candidates minus the permanently-un-enqueueable skip reasons (excluded,
  # unavailable). Parses the actual numbers out of the summary line rather
  # than hardcoding a total, so this does not go brittle as other fixture
  # cases are added. The same $out from Check 1/2 already exercises both
  # skip reasons (case c -> excluded, the missing-checkout case -> repo
  # unavailable) alongside real candidates (case a, case i), so no new run
  # is needed here. ----
  total=$((total + 1))
  local summary_line sc_candidates sc_excluded sc_unavailable sc_actionable
  summary_line="$(echo "$out" | grep '^roborev_requeue_dropped \[dry-run\]: candidates=')"
  sc_candidates="$(echo "$summary_line" | grep -oE 'candidates=[0-9]+' | cut -d= -f2)"
  sc_excluded="$(echo "$summary_line" | grep -oE 'skipped_excluded=[0-9]+' | cut -d= -f2)"
  sc_unavailable="$(echo "$summary_line" | grep -oE 'skipped_unavailable=[0-9]+' | cut -d= -f2)"
  sc_actionable="$(echo "$summary_line" | grep -oE 'actionable=[0-9]+' | cut -d= -f2)"
  if [ -n "$sc_candidates" ] && [ -n "$sc_actionable" ] \
     && [ "${sc_excluded:-0}" -gt 0 ] && [ "${sc_unavailable:-0}" -gt 0 ] \
     && [ "$sc_actionable" = "$((sc_candidates - sc_excluded - sc_unavailable))" ]; then
    pass=$((pass + 1))
  else
    echo "FAIL: actionable count wrong, or fixture no longer produces both an excluded and an unavailable candidate (candidates=$sc_candidates skipped_excluded=$sc_excluded skipped_unavailable=$sc_unavailable actionable=$sc_actionable). Summary line:"
    echo "$summary_line"
  fi

  # ---- Check 3: repo_unavailable case is skipped, not enqueued ----
  total=$((total + 1))
  if echo "$out" | grep -q "skip.*repo_unavailable.*deadbeef"; then
    pass=$((pass + 1))
  else
    echo "FAIL: missing-checkout candidate was not reported as skip/repo_unavailable. Output:"
    echo "$out"
  fi

  # ---- Check 4: non-quota failure never becomes a candidate ----
  total=$((total + 1))
  if ! echo "$out" | grep -q "${sha_nonquota}"; then
    pass=$((pass + 1))
  else
    echo "FAIL: a non-quota failure was treated as a candidate. Output:"
    echo "$out"
  fi

  # ---- Check 4c (llm#964 case h): earlier quota failure, later non-quota
  # failure -> latest job wins, pair must NOT be a candidate at all — not
  # even reported as a skip line, since it should never enter the result
  # set (this is the exact coMMpass shape this dispatch fixes; against the
  # pre-fix candidate query this check fails because the stale quota row
  # keeps the pair eligible forever). ----
  total=$((total + 1))
  if ! echo "$out" | grep -q "${sha_h}"; then
    pass=$((pass + 1))
  else
    echo "FAIL: a pair whose LATEST job is a non-quota failure was still treated as a candidate (llm#964 case h — stale quota row keeps it eligible). Output:"
    echo "$out"
  fi

  # ---- Check 4d (llm#964 case i): earlier non-quota failure, later quota
  # failure -> latest job wins the OTHER direction: pair MUST remain a
  # candidate. ----
  total=$((total + 1))
  if echo "$out" | grep -q "would enqueue.*${sha_i}"; then
    pass=$((pass + 1))
  else
    echo "FAIL: a pair whose LATEST job is a quota failure (despite an earlier non-quota failure) was not offered as a candidate (llm#964 case i). Output:"
    echo "$out"
  fi

  # ---- Check 4b: git_failed (repo exists, but sha is not a valid object —
  # e.g. history was rewritten since the review job was recorded) is
  # correctly labelled git_failed, not misread as no_files_reported via
  # grep's own exit status (PIPESTATUS regression guard). ----
  total=$((total + 1))
  local verdict_bad_sha
  verdict_bad_sha="$(commit_excluded "$fake_git_repo" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "inst/extdata/**")"
  if [ "$verdict_bad_sha" = "git_failed" ]; then
    pass=$((pass + 1))
  else
    echo "FAIL: bad-object sha expected verdict 'git_failed', got '$verdict_bad_sha'"
  fi

  # ---- Check 5: rate limit honoured under --apply ----
  # Add two more distinct quota-failed real-code candidates so there are 3
  # eligible candidates total, then cap --limit=2 and confirm exactly 2 are
  # enqueued (2 fake_roborev invocations), the 3rd reported as rate_limit.
  local sha_real2 sha_real3
  echo 'g <- function() 2' > "$fake_git_repo/R/bar.R"
  "$git_bin" -C "$fake_git_repo" add -A
  "$git_bin" -C "$fake_git_repo" commit -q -m "feat: real code 2"
  sha_real2="$("$git_bin" -C "$fake_git_repo" rev-parse HEAD)"
  echo 'h <- function() 3' > "$fake_git_repo/R/baz.R"
  "$git_bin" -C "$fake_git_repo" add -A
  "$git_bin" -C "$fake_git_repo" commit -q -m "feat: real code 3"
  sha_real3="$("$git_bin" -C "$fake_git_repo" rev-parse HEAD)"

  "$sqlite_bin" "$fixture_db" <<SQL
INSERT INTO commits VALUES (6, 1, '${sha_real2}', 'feat: real code 2');
INSERT INTO commits VALUES (7, 1, '${sha_real3}', 'feat: real code 3');
INSERT INTO review_jobs VALUES (106, 1, 6, '${sha_real2}', 'failed', 'quota: agent: codex failed: Quota exceeded.', '2026-03-01 00:00:00');
INSERT INTO review_jobs VALUES (107, 1, 7, '${sha_real3}', 'failed', 'quota: agent: codex failed: Quota exceeded.', '2026-03-01 00:01:00');
SQL

  total=$((total + 1))
  : > "$fake_roborev_log"
  local apply_out
  apply_out="$(ROBOREV_DB="$fixture_db" SQLITE="$sqlite_bin" ROBOREV="$fake_roborev" GIT_BIN="$git_bin" \
    UNIFIED_DB_PATH="$fake_hk_db" LOG_FILE_PATH="${tmp_root}/log2.log" FAKE_ROBOREV_LOG="$fake_roborev_log" \
    bash "$0" --apply --limit=2 2>&1)"
  local invocations
  invocations="$(wc -l < "$fake_roborev_log" | tr -d ' ')"
  if [ "$invocations" = "2" ] && echo "$apply_out" | grep -q "rate_limit"; then
    pass=$((pass + 1))
  else
    echo "FAIL: rate limit not honoured (expected 2 fake roborev invocations, got $invocations). Output:"
    echo "$apply_out"
  fi

  # ---- Check 6: idempotency — a pre-existing queued job for the SAME ref
  # must not be re-enqueued (excluded from candidates entirely). ----
  total=$((total + 1))
  "$sqlite_bin" "$fixture_db" "INSERT INTO review_jobs VALUES (108, 1, 6, '${sha_real2}', 'queued', NULL, '2026-03-02 00:00:00');"
  local idem_out
  idem_out="$(ROBOREV_DB="$fixture_db" SQLITE="$sqlite_bin" ROBOREV="$fake_roborev" GIT_BIN="$git_bin" \
    UNIFIED_DB_PATH="$fake_hk_db" LOG_FILE_PATH="${tmp_root}/log3.log" FAKE_ROBOREV_LOG="$fake_roborev_log" \
    bash "$0" --dry-run --limit=10 2>&1)"
  if ! echo "$idem_out" | grep -q "${sha_real2}"; then
    pass=$((pass + 1))
  else
    echo "FAIL: a ref with an existing queued job was still offered as a candidate. Output:"
    echo "$idem_out"
  fi

  # ---- Check 7: housekeeping heartbeat written even on a zero-candidate run ----
  total=$((total + 1))
  local empty_db="${tmp_root}/empty_reviews.db"
  "$sqlite_bin" "$empty_db" <<'SQL'
CREATE TABLE repos (id INTEGER PRIMARY KEY, root_path TEXT UNIQUE NOT NULL, name TEXT NOT NULL);
CREATE TABLE commits (id INTEGER PRIMARY KEY, repo_id INTEGER NOT NULL, sha TEXT NOT NULL, subject TEXT NOT NULL);
CREATE TABLE review_jobs (id INTEGER PRIMARY KEY, repo_id INTEGER NOT NULL, commit_id INTEGER, git_ref TEXT NOT NULL, status TEXT NOT NULL, error TEXT, enqueued_at TEXT NOT NULL DEFAULT '2026-01-01 00:00:00');
SQL
  local empty_hk_db="${tmp_root}/empty_unified.duckdb"
  duckdb -init /dev/null "$empty_hk_db" < "${_SCRIPT_DIR}/housekeeping_schema_init.sql" >/dev/null 2>&1 || true
  ROBOREV_DB="$empty_db" SQLITE="$sqlite_bin" ROBOREV="$fake_roborev" GIT_BIN="$git_bin" \
    UNIFIED_DB_PATH="$empty_hk_db" LOG_FILE_PATH="${tmp_root}/log4.log" FAKE_ROBOREV_LOG="$fake_roborev_log" \
    bash "$0" --dry-run >/dev/null 2>&1
  local hb_row
  hb_row="$(duckdb -init /dev/null -noheader -list "$empty_hk_db" -c "
    SELECT status || '|' || rows_written FROM housekeeping_runs WHERE task='roborev_requeue_dropped';
  " 2>/dev/null)"
  if [ "$hb_row" = "ok|0" ]; then
    pass=$((pass + 1))
  else
    echo "FAIL: expected an 'ok|0' heartbeat row on a zero-candidate run, got '$hb_row'"
  fi

  # ---- Check 8 (llm#964 defect 2): round-robin ordering across repos ----
  # Two independent repos, 'aaa' and 'zzz', each with 3 eligible
  # quota-failed candidates and NOTHING else in this isolated DB (kept
  # separate from fixture_db above so repo-1/repo-2's own candidates can't
  # skew which repo's turn it is). With --limit=2, one candidate from EACH
  # repo must be selected — not two from whichever repo sorts first
  # alphabetically. This mirrors the measured real-DB starvation:
  # candidates=153 enqueued=5 skipped_rate_limit=51 on two consecutive
  # thrice-daily runs, same 51 skipped both times, because 'coMMpass'
  # (sorts before every other repo name) consumed the entire --limit=5
  # budget on every single run.
  total=$((total + 1))
  local rr_root="${tmp_root}/roundrobin"
  mkdir -p "$rr_root"
  local rr_repo_aaa="${rr_root}/aaa"
  local rr_repo_zzz="${rr_root}/zzz"
  local rr_repo_path
  for rr_repo_path in "$rr_repo_aaa" "$rr_repo_zzz"; do
    mkdir -p "$rr_repo_path/R"
    "$git_bin" -C "$rr_repo_path" init -q -b main
    "$git_bin" -C "$rr_repo_path" config user.email "test@example.com"
    "$git_bin" -C "$rr_repo_path" config user.name "Test"
    local rr_n
    for rr_n in 1 2 3; do
      echo "v${rr_n} <- function() ${rr_n}" > "$rr_repo_path/R/v${rr_n}.R"
      "$git_bin" -C "$rr_repo_path" add -A
      "$git_bin" -C "$rr_repo_path" commit -q -m "feat: candidate ${rr_n}"
    done
  done
  local sha_aaa1 sha_aaa2 sha_aaa3 sha_zzz1 sha_zzz2 sha_zzz3
  sha_aaa1="$("$git_bin" -C "$rr_repo_aaa" log --format=%H --reverse | sed -n '1p')"
  sha_aaa2="$("$git_bin" -C "$rr_repo_aaa" log --format=%H --reverse | sed -n '2p')"
  sha_aaa3="$("$git_bin" -C "$rr_repo_aaa" log --format=%H --reverse | sed -n '3p')"
  sha_zzz1="$("$git_bin" -C "$rr_repo_zzz" log --format=%H --reverse | sed -n '1p')"
  sha_zzz2="$("$git_bin" -C "$rr_repo_zzz" log --format=%H --reverse | sed -n '2p')"
  sha_zzz3="$("$git_bin" -C "$rr_repo_zzz" log --format=%H --reverse | sed -n '3p')"

  local rr_db="${rr_root}/reviews.db"
  "$sqlite_bin" "$rr_db" <<SQL
CREATE TABLE repos (id INTEGER PRIMARY KEY, root_path TEXT UNIQUE NOT NULL, name TEXT NOT NULL);
CREATE TABLE commits (id INTEGER PRIMARY KEY, repo_id INTEGER NOT NULL, sha TEXT NOT NULL, subject TEXT NOT NULL);
CREATE TABLE review_jobs (id INTEGER PRIMARY KEY, repo_id INTEGER NOT NULL, commit_id INTEGER, git_ref TEXT NOT NULL, status TEXT NOT NULL, error TEXT, enqueued_at TEXT NOT NULL DEFAULT '2026-04-01 00:00:00');

INSERT INTO repos VALUES (1, '${rr_repo_aaa}', 'aaa');
INSERT INTO repos VALUES (2, '${rr_repo_zzz}', 'zzz');

INSERT INTO commits VALUES (1, 1, '${sha_aaa1}', 'feat: candidate 1');
INSERT INTO commits VALUES (2, 1, '${sha_aaa2}', 'feat: candidate 2');
INSERT INTO commits VALUES (3, 1, '${sha_aaa3}', 'feat: candidate 3');
INSERT INTO commits VALUES (4, 2, '${sha_zzz1}', 'feat: candidate 1');
INSERT INTO commits VALUES (5, 2, '${sha_zzz2}', 'feat: candidate 2');
INSERT INTO commits VALUES (6, 2, '${sha_zzz3}', 'feat: candidate 3');

INSERT INTO review_jobs VALUES (1, 1, 1, '${sha_aaa1}', 'failed', 'quota: agent: codex failed: Quota exceeded.', '2026-04-01 00:00:00');
INSERT INTO review_jobs VALUES (2, 1, 2, '${sha_aaa2}', 'failed', 'quota: agent: codex failed: Quota exceeded.', '2026-04-01 00:00:00');
INSERT INTO review_jobs VALUES (3, 1, 3, '${sha_aaa3}', 'failed', 'quota: agent: codex failed: Quota exceeded.', '2026-04-01 00:00:00');
INSERT INTO review_jobs VALUES (4, 2, 4, '${sha_zzz1}', 'failed', 'quota: agent: codex failed: Quota exceeded.', '2026-04-01 00:00:00');
INSERT INTO review_jobs VALUES (5, 2, 5, '${sha_zzz2}', 'failed', 'quota: agent: codex failed: Quota exceeded.', '2026-04-01 00:00:00');
INSERT INTO review_jobs VALUES (6, 2, 6, '${sha_zzz3}', 'failed', 'quota: agent: codex failed: Quota exceeded.', '2026-04-01 00:00:00');
SQL

  local rr_hk_db="${rr_root}/unified.duckdb"
  duckdb -init /dev/null "$rr_hk_db" < "${_SCRIPT_DIR}/housekeeping_schema_init.sql" >/dev/null 2>&1 || true
  local rr_out
  rr_out="$(ROBOREV_DB="$rr_db" SQLITE="$sqlite_bin" ROBOREV="$fake_roborev" GIT_BIN="$git_bin" \
    UNIFIED_DB_PATH="$rr_hk_db" LOG_FILE_PATH="${tmp_root}/log_rr.log" FAKE_ROBOREV_LOG="$fake_roborev_log" \
    bash "$0" --dry-run --limit=2 2>&1)"
  local rr_aaa_count rr_zzz_count
  rr_aaa_count="$(echo "$rr_out" | grep -c "would enqueue: aaa ")"
  rr_zzz_count="$(echo "$rr_out" | grep -c "would enqueue: zzz ")"
  if [ "$rr_aaa_count" = "1" ] && [ "$rr_zzz_count" = "1" ]; then
    pass=$((pass + 1))
  else
    echo "FAIL: round-robin ordering not honoured (expected 1 aaa + 1 zzz 'would enqueue' line, got aaa=$rr_aaa_count zzz=$rr_zzz_count). Output:"
    echo "$rr_out"
  fi

  rm -rf "$tmp_root" 2>/dev/null || true

  echo "selftest: ${pass}/${total} PASS"
  [ "$pass" -eq "$total" ]
}

if [ "$MODE" = "selftest" ]; then
  run_selftest
  exit $?
fi

# ---------------------------------------------------------------------------
# Main sweep
# ---------------------------------------------------------------------------

# Quietly succeed if any required binary/DB missing (laptop vs CI portability,
# same posture as roborev_poll_merges.sh).
for cmd in "$DB" "$SQLITE" "$ROBOREV" "$GIT_BIN"; do
  if [ ! -e "$cmd" ]; then
    log "skip: $cmd not found"
    echo "roborev_requeue_dropped: skipped ($cmd missing)"
    exit 0
  fi
done

# llm#964: both the latest-job-wins candidate filter and the round-robin
# ordering below depend on SQLite window functions (ROW_NUMBER() OVER ...),
# available since SQLite 3.25 (2018-09). Probe once, fail loudly rather than
# silently falling back to an unordered/unfiltered query — a silent
# degrade here would quietly reintroduce either defect on whatever machine
# lacks a modern sqlite3 binary.
if ! "$SQLITE" ":memory:" "SELECT ROW_NUMBER() OVER (ORDER BY 1);" >/dev/null 2>&1; then
  echo "roborev_requeue_dropped: sqlite3 ($SQLITE) lacks window-function support (need 3.25+); refusing to run rather than silently degrade candidate selection (llm#964)" >&2
  log "abort: sqlite3 lacks window function support"
  exit 1
fi

hk_run_start

CANDIDATES_SQL="
WITH ranked AS (
  -- llm#964 latest-job-wins: rank every job for a (repo_id, commit_id)
  -- pair by recency; rn=1 is that pair's single most-recent attempt.
  -- enqueued_at has only second-level resolution and rapid requeues can
  -- collide, so tie-break on id DESC (higher id == inserted later).
  SELECT
    repo_id, commit_id, status, error,
    ROW_NUMBER() OVER (
      PARTITION BY repo_id, commit_id
      ORDER BY enqueued_at DESC, id DESC
    ) AS rn
  FROM review_jobs
  WHERE commit_id IS NOT NULL
),
quota_failed AS (
  -- Only a pair whose LATEST job is itself a quota failure is still worth
  -- retrying — see the 'Latest-job-wins' header comment above for the
  -- coMMpass case this fixes (a stale quota row must not keep a pair
  -- eligible once its most recent attempt failed for a different reason).
  SELECT DISTINCT repo_id, commit_id
  FROM ranked
  WHERE rn = 1 AND status='failed' AND ${QUOTA_ERROR_SQL}
),
ok AS (
  SELECT DISTINCT repo_id, commit_id FROM review_jobs
  WHERE status IN ('done','applied','rebased') AND commit_id IS NOT NULL
),
pending AS (
  SELECT DISTINCT repo_id, commit_id FROM review_jobs
  WHERE status IN ('queued','running') AND commit_id IS NOT NULL
),
candidates AS (
  SELECT r.id AS repo_id, r.name AS repo_name, r.root_path AS root_path,
         c.id AS commit_row_id, c.sha AS sha, c.subject AS subject
  FROM quota_failed qf
  JOIN repos r ON r.id = qf.repo_id
  JOIN commits c ON c.id = qf.commit_id
  LEFT JOIN ok o ON o.repo_id = qf.repo_id AND o.commit_id = qf.commit_id
  LEFT JOIN pending p ON p.repo_id = qf.repo_id AND p.commit_id = qf.commit_id
  WHERE o.repo_id IS NULL AND p.repo_id IS NULL
)
-- llm#964 round-robin: without this, ORDER BY r.name, c.sha lets whichever
-- repo sorts alphabetically first (e.g. 'coMMpass') consume the entire
-- --limit budget on every single run, starving every other repo's
-- candidates permanently (measured: candidates=153 enqueued=5
-- skipped_rate_limit=51 on two consecutive real runs, same 51 skipped both
-- times). Interleaving the Nth candidate of every repo before the (N+1)th
-- of any repo means the rate limit spends its budget across repos instead
-- of exhausting itself on one.
SELECT repo_id, repo_name, root_path, commit_row_id, sha, subject
FROM candidates
ORDER BY ROW_NUMBER() OVER (PARTITION BY repo_name ORDER BY sha), repo_name, sha;
"

candidates=0
enqueued=0
skipped_excluded=0
skipped_unavailable=0
skipped_rate_limit=0

while IFS=$'\x1f' read -r repo_id repo_name root_path commit_id sha subject; do
  [ -n "$repo_id" ] || continue
  candidates=$((candidates + 1))

  IFS=$'\x1f' read -r -a patterns < <(get_exclude_patterns "$root_path" | tr '\n' $'\x1f')

  verdict="$(commit_excluded "$root_path" "$sha" "${patterns[@]}")"

  case "$verdict" in
    excluded)
      skipped_excluded=$((skipped_excluded + 1))
      log "skip(excluded): $repo_name $sha — every changed file matches exclude_patterns"
      echo "skip(excluded): $repo_name $sha — ${subject}"
      continue
      ;;
    repo_unavailable|git_failed|no_files_reported)
      skipped_unavailable=$((skipped_unavailable + 1))
      log "skip($verdict): $repo_name $sha"
      echo "skip($verdict): $repo_name $sha — ${subject}"
      continue
      ;;
  esac

  if [ "$enqueued" -ge "$LIMIT" ]; then
    skipped_rate_limit=$((skipped_rate_limit + 1))
    log "skip(rate_limit): $repo_name $sha — --limit=$LIMIT already reached"
    echo "skip(rate_limit): $repo_name $sha — ${subject}"
    continue
  fi

  if [ "$MODE" = "dry-run" ]; then
    enqueued=$((enqueued + 1))
    log "[dry] would enqueue: $repo_name $sha"
    echo "[dry] would enqueue: $repo_name $sha — ${subject}"
  else
    if "$ROBOREV" review --sha "$sha" --repo "$root_path" >/dev/null 2>&1; then
      enqueued=$((enqueued + 1))
      log "enqueued: $repo_name $sha"
      echo "enqueued: $repo_name $sha — ${subject}"
    else
      skipped_unavailable=$((skipped_unavailable + 1))
      log "fail: roborev review --sha $sha --repo $root_path failed"
      echo "fail: $repo_name $sha — roborev review invocation failed"
    fi
  fi
done < <("$SQLITE" -separator $'\x1f' "$DB" "$CANDIDATES_SQL")

mode_label="dry-run"; [ "$MODE" = "apply" ] && mode_label="applied"
# llm#966: actionable excludes candidates that can NEVER be enqueued
# (permanently excluded-path-only, or repo checkout unavailable) — see the
# "Reported actionable count" header comment above.
actionable=$((candidates - skipped_excluded - skipped_unavailable))
summary="roborev_requeue_dropped [$mode_label]: candidates=$candidates enqueued=$enqueued skipped_excluded=$skipped_excluded skipped_unavailable=$skipped_unavailable skipped_rate_limit=$skipped_rate_limit limit=$LIMIT actionable=$actionable"
log "summary: $summary"
echo "$summary"

detail_json="{\"mode\":\"${MODE}\",\"limit\":${LIMIT},\"candidates\":${candidates},\"enqueued\":${enqueued},\"skipped_excluded\":${skipped_excluded},\"skipped_unavailable\":${skipped_unavailable},\"skipped_rate_limit\":${skipped_rate_limit},\"actionable\":${actionable}}"
hk_run_end "ok" "$enqueued" "$detail_json"

exit 0
