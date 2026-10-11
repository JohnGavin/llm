#!/usr/bin/env bash
# repo_visibility_diff.sh -- daily GitHub repo-visibility diff (llm#1371,
# privacy gate 7).
#
# repo_visibility_guard.sh blocks a visibility change made BY Claude. A repo
# made public on github.com, or created public by hand, is never checked by it.
# This job closes that gap: every run it lists every repo of the authenticated
# owner and of every org the user belongs to (visibility + created_at), stores
# the listing as a snapshot, and diffs it against the previous snapshot.
#
# A FINDING is a repo that
#   - became_public: was in the previous snapshot (same created_at) and was not
#                    PUBLIC, and is PUBLIC now; or
#   - new_public:    is absent from the previous snapshot (or was recreated under
#                    the same name with a different created_at) and is PUBLIC.
# Becoming private, new private repos and deleted repos are not findings.
#
# Each finding is recorded in repo_visibility_changes and triggers an immediate
# full-history audit: a fresh `git clone --mirror` of the repo, then
# private_data_history_audit.sh in its single-repo mode (REPO_ROOT +
# PDHA_REPO_NAME in the environment; this script does not edit or depend on
# any multi-repo flag of that script, JohnGavin/llm#1367). If the audit cannot
# complete (clone failed, audit script missing, audit INDETERMINATE) the change
# stays audit_status='pending' and is RETRIED on every later run, and a pending
# audit keeps the exit code at 1: a public repo nobody has audited is not clean.
#
# Note on the audit ledger: private_data_history_audit.sh refuses to run
# (exit 3) until a baseline exists in private_data_history_findings. Run
# `private_data_history_audit.sh --baseline` once; until then every audit this
# job triggers stays 'pending' and says so.
#
# ─── Exit codes (checks-must-distinguish-unknown) ───────────────────────────
#   0  ran; no finding and no audit outstanding. Also the FIRST run ever: with
#      no previous snapshot there is nothing to diff, so the run records a
#      BASELINE (loudly logged and printed) and reports nothing.
#   1  >= 1 finding this run, OR a finding whose audit is still pending, OR an
#      audit that reported findings.
#   2  usage error.
#   3  INDETERMINATE: the visibility of the repos could not be established --
#      gh missing or any API call failed, a malformed or implausible listing
#      (no repos at all for the user, a listing at the 1000-row cap, a bad
#      row), duckdb missing, or the snapshot DB/table missing or unwritable.
#      Never reported as "no change"; nothing is written to the snapshot table.
#
# Usage:
#   repo_visibility_diff.sh              # run
#   repo_visibility_diff.sh --selftest   # stubbed gh, temp DB, exact exit codes
#
# Env: UNIFIED_DB_PATH (default ~/.claude/logs/unified.duckdb), GH_BIN (default
#   gh), VD_AUDIT_CMD (default private_data_history_audit.sh next to this
#   script), OSASCRIPT_BIN (default osascript; absent = no notification),
#   SKIP_CRON_PULL (cron-auto-pull-discipline).
#
# Prerequisite: the tables exist (bash .claude/scripts/housekeeping_schema_apply.sh).
# Log: ~/.claude/logs/repo_visibility_diff.log
# Housekeeping: housekeeping_runs (task='repo_visibility_diff'; rows_written =
#   findings recorded this run; status 'partial' = INDETERMINATE).
# Delivered launchd plist (NOT installed by this change):
#   .claude/launchd/com.claude.repo-visibility-diff.plist

set -uo pipefail

export PATH="/nix/var/nix/profiles/default/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

HOME_DIR="${HOME:-/Users/johngavin}"
LOG_DIR="${HOME_DIR}/.claude/logs"
LOG_FILE="${LOG_DIR}/repo_visibility_diff.log"
UNIFIED_DB="${UNIFIED_DB_PATH:-${HOME_DIR}/.claude/logs/unified.duckdb}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR/../.." && pwd))"
SCHEMA_SQL="${SCRIPT_DIR}/housekeeping_schema_init.sql"
GH="${GH_BIN:-gh}"
AUDIT="${VD_AUDIT_CMD:-${SCRIPT_DIR}/private_data_history_audit.sh}"
OSA="${OSASCRIPT_BIN:-osascript}"
LIST_LIMIT=1000

HK_TASK="repo_visibility_diff"
_run_id=""
_duckdb_ok=0
TMPD=""

log_line() {
    { mkdir -p "$LOG_DIR" 2>/dev/null
      printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" "$1" >> "$LOG_FILE"
    } 2>/dev/null || true
}

hk_run_start() {
    [ "$_duckdb_ok" = "1" ] || return 0
    _run_id="$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    [ -n "$_run_id" ] || return 0
    duckdb -init /dev/null "$UNIFIED_DB" -c "
        INSERT OR IGNORE INTO housekeeping_runs
          (id, task, source_script, started_at, status, rows_written)
        VALUES ('${_run_id}', '${HK_TASK}', '${SCRIPT_DIR}/repo_visibility_diff.sh',
                current_timestamp, 'ok', 0);
    " >/dev/null 2>&1 || true
}

hk_run_end() {
    [ "$_duckdb_ok" = "1" ] || return 0
    [ -n "$_run_id" ] || return 0
    duckdb -init /dev/null "$UNIFIED_DB" -c "
        UPDATE housekeeping_runs SET ended_at = current_timestamp, status = '$1', rows_written = ${2:-0}
        WHERE id = '${_run_id}';
    " >/dev/null 2>&1 || true
}

# notify TITLE MESSAGE -- macOS notification, best effort. Messages carry only
# validated repo names and counts (no quote or backslash can occur).
notify() {
    command -v "$OSA" >/dev/null 2>&1 || return 0
    "$OSA" -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1 || true
}

db_query() { duckdb -init /dev/null -bail -csv -noheader "$UNIFIED_DB" -c "$1" 2>"$TMPD/dberr"; }

# indeterminate REASON -- exit 3; never reported as no-change
indeterminate() {
    echo "" >&2
    echo "repo_visibility_diff: INDETERMINATE -- $1" >&2
    echo "Repo visibility could not be established; this is NOT a no-change result (exit 3)." >&2
    log_line "status=indeterminate rc=3 reason=$(printf '%s' "$1" | tr '\t\n' '  ')"
    hk_run_end "partial" "0"
    notify "repo_visibility_diff" "INDETERMINATE: could not check repo visibility"
    exit 3
}

# list_owner OWNER OUTFILE -- append validated-later TSV rows (repo, VISIBILITY, created_at)
list_owner() {
    local owner="$1" out="$2" n
    "$GH" repo list "$owner" --limit "$LIST_LIMIT" --json nameWithOwner,visibility,createdAt \
        --jq '.[] | [.nameWithOwner, .visibility, .createdAt] | @tsv' \
        >"$TMPD/list.$$" 2>"$TMPD/list.err" \
        || indeterminate "gh repo list ${owner} failed: $(head -c 200 "$TMPD/list.err" | tr '\n' ' ')"
    n="$(wc -l < "$TMPD/list.$$" | tr -d ' ')"
    if [ "$n" -ge "$LIST_LIMIT" ]; then
        indeterminate "gh repo list ${owner} returned ${n} rows, the --limit cap (${LIST_LIMIT}): the listing may be truncated"
    fi
    cat "$TMPD/list.$$" >> "$out"
    echo "$n"
}

run_main() {
    TMPD="$(mktemp -d "${TMPDIR:-/tmp}/repo_vis_diff.XXXXXX")"
    trap 'rm -rf "$TMPD"' EXIT

    # ── Deploy: pull latest main before running (cron-auto-pull-discipline, llm#510) ──
    if [ -z "${SKIP_CRON_PULL:-}" ]; then
        git -C "$REPO_ROOT" fetch origin main 2>/dev/null
        if git -C "$REPO_ROOT" merge --ff-only origin/main 2>/dev/null; then
            log_line "deploy: ff to $(git -C "$REPO_ROOT" rev-parse --short HEAD)"
        else
            log_line "deploy WARN: ff-only failed -- running against $(git -C "$REPO_ROOT" rev-parse --short HEAD)"
        fi
    fi
    log_line "HEAD: $(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null) $(git -C "$REPO_ROOT" log -1 --format='%s' 2>/dev/null)"

    command -v duckdb >/dev/null 2>&1 && [ -f "$UNIFIED_DB" ] && _duckdb_ok=1
    hk_run_start

    command -v duckdb >/dev/null 2>&1 || indeterminate "duckdb is not on PATH (cannot store or diff snapshots)"
    [ -f "$UNIFIED_DB" ] || indeterminate "snapshot database not found at ${UNIFIED_DB}"
    command -v "$GH" >/dev/null 2>&1 || indeterminate "gh is not on PATH (GH_BIN=${GH})"
    [ -n "$_run_id" ] || indeterminate "could not mint a run id (uuidgen) -- snapshot cannot be keyed"

    # Pre-flight: tables readable, and the previous snapshot (if any).
    PREV="$(db_query "SELECT snapshot_id FROM repo_visibility_snapshots ORDER BY observed_at DESC, snapshot_id LIMIT 1")" \
        || indeterminate "snapshot tables unusable -- apply the schema with housekeeping_schema_apply.sh ($(head -c 200 "$TMPD/dberr" | tr '\n' ' '))"
    db_query "SELECT count(*) FROM repo_visibility_changes" >/dev/null \
        || indeterminate "repo_visibility_changes unusable -- apply the schema with housekeeping_schema_apply.sh ($(head -c 200 "$TMPD/dberr" | tr '\n' ' '))"
    if [ -n "$PREV" ] && ! printf '%s' "$PREV" | grep -qE '^[0-9a-f-]+$'; then
        indeterminate "previous snapshot id is malformed"
    fi

    # ── 1. Enumerate: the user, then every org the user belongs to ───────────
    LOGIN="$("$GH" api user --jq .login 2>"$TMPD/e1")" \
        || indeterminate "gh api user failed: $(head -c 200 "$TMPD/e1" | tr '\n' ' ')"
    printf '%s' "$LOGIN" | grep -qE '^[A-Za-z0-9-]+$' \
        || indeterminate "gh api user returned no usable login"
    "$GH" api user/orgs --paginate --jq '.[].login' >"$TMPD/orgs" 2>"$TMPD/e2" \
        || indeterminate "gh api user/orgs failed: $(head -c 200 "$TMPD/e2" | tr '\n' ' ')"
    if grep -qvE '^[A-Za-z0-9-]+$' "$TMPD/orgs"; then
        indeterminate "gh api user/orgs returned a malformed org login"
    fi

    : > "$TMPD/raw.tsv"
    N_USER="$(list_owner "$LOGIN" "$TMPD/raw.tsv")" || exit $?
    if [ "${N_USER:-0}" -eq 0 ]; then
        indeterminate "gh repo list ${LOGIN} returned no repos (implausible for the owner; treated as a failed listing, not as 'no repos')"
    fi
    N_ORGS=0
    while IFS= read -r org; do
        [ -n "$org" ] || continue
        N_ORGS=$((N_ORGS + 1))
        list_owner "$org" "$TMPD/raw.tsv" >/dev/null || exit $?
    done < "$TMPD/orgs"

    # ── 2. Validate every row; an unparseable row is INDETERMINATE ───────────
    BAD="$(awk -F'\t' '
        NF != 3 { bad++; next }
        $1 !~ /^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/ { bad++; next }
        $2 !~ /^(PUBLIC|PRIVATE|INTERNAL)$/ { bad++; next }
        $3 !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9:.]+Z?$/ { bad++; next }
        END { print bad + 0 }' "$TMPD/raw.tsv")"
    [ "$BAD" = "0" ] || indeterminate "${BAD} malformed row(s) in the repo listing (bad repo name, visibility or created_at, or wrong column count)"
    sort -u "$TMPD/raw.tsv" > "$TMPD/cur.tsv"
    N_REPOS="$(wc -l < "$TMPD/cur.tsv" | tr -d ' ')"
    N_PUBLIC="$(awk -F'\t' '$2=="PUBLIC"{n++} END{print n+0}' "$TMPD/cur.tsv")"

    # ── 3. Snapshot + diff in one transaction ────────────────────────────────
    cat > "$TMPD/apply.sql" <<SQL
BEGIN TRANSACTION;
CREATE TEMP TABLE cur AS
  SELECT repo, visibility, created_at
  FROM read_csv('${TMPD}/cur.tsv', delim='\t', header=false, quote='', escape='', auto_detect=false,
                columns={'repo':'VARCHAR','visibility':'VARCHAR','created_at':'VARCHAR'});
INSERT OR IGNORE INTO repo_visibility_changes
  (id, detected_at, snapshot_id, repo, repo_created_at, change_type, prev_visibility, audit_status)
  SELECT '${_run_id}|' || c.repo, current_timestamp, '${_run_id}', c.repo, c.created_at,
         CASE WHEN p.repo IS NULL THEN 'new_public' ELSE 'became_public' END,
         p.visibility, 'pending'
  FROM cur c
  LEFT JOIN repo_visibility_snapshots p
    ON p.snapshot_id = '${PREV}' AND p.repo = c.repo AND p.created_at = c.created_at
  WHERE '${PREV}' <> '' AND c.visibility = 'PUBLIC' AND (p.repo IS NULL OR p.visibility <> 'PUBLIC');
INSERT OR IGNORE INTO repo_visibility_snapshots (id, snapshot_id, observed_at, repo, visibility, created_at)
  SELECT '${_run_id}|' || repo, '${_run_id}', current_timestamp, repo, visibility, created_at FROM cur;
COMMIT;
SQL
    duckdb -init /dev/null -bail "$UNIFIED_DB" < "$TMPD/apply.sql" >"$TMPD/db.out" 2>"$TMPD/db.err" \
        || indeterminate "could not record the snapshot ($(head -c 200 "$TMPD/db.err" | tr '\n' ' '))"

    if [ -z "$PREV" ]; then
        echo "repo_visibility_diff: BASELINE -- no previous snapshot existed, so there is nothing to diff."
        echo "repo_visibility_diff: recorded ${N_REPOS} repo(s) (${N_PUBLIC} public) across ${LOGIN} + ${N_ORGS} org(s). Future runs alert on changes from this snapshot."
        echo "repo_visibility_diff: repos already public at baseline are NOT audited here (full-history audit of existing public repos is a separate job, llm#1367)."
        log_line "mode=baseline repos=${N_REPOS} public=${N_PUBLIC} owners=$((N_ORGS + 1)) findings=0 status=baseline rc=0"
        hk_run_end "ok" "0"
        exit 0
    fi

    N_NEW="$(db_query "SELECT count(*) FROM repo_visibility_changes WHERE snapshot_id = '${_run_id}'")" \
        || indeterminate "could not count this run's findings ($(head -c 200 "$TMPD/dberr" | tr '\n' ' '))"

    echo "repo_visibility_diff: repos=${N_REPOS} public=${N_PUBLIC} owners=$((N_ORGS + 1)) new_findings=${N_NEW}"
    if [ "$N_NEW" -gt 0 ]; then
        db_query "SELECT change_type || ' ' || repo || ' (previous visibility: ' || coalesce(prev_visibility, 'none, new repo') || ', created ' || repo_created_at || ')' FROM repo_visibility_changes WHERE snapshot_id = '${_run_id}' ORDER BY repo" \
            | sed 's/^"//; s/"$//; s/^/  FINDING /'
    fi

    # ── 4. Audit every change whose audit has not completed (new + retries) ──
    db_query "SELECT id || ' ' || repo FROM repo_visibility_changes WHERE audit_status = 'pending' ORDER BY detected_at, repo" \
        | sed 's/^"//; s/"$//' > "$TMPD/pending.txt" \
        || indeterminate "could not read pending audits ($(head -c 200 "$TMPD/dberr" | tr '\n' ' '))"

    AUDIT_FINDINGS=0
    N_PENDING_LEFT=0
    while read -r cid crepo; do
        [ -n "$cid" ] || continue
        printf '%s' "$cid" | grep -qE '^[0-9a-f-]+\|[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' || continue
        printf '%s' "$crepo" | grep -qE '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' || continue
        mdir="$TMPD/mirror.$$.$(printf '%s' "$crepo" | tr '/' '_')"
        echo "repo_visibility_diff: auditing full history of ${crepo} (fresh mirror clone)"
        arc=125
        if "$GH" repo clone "$crepo" "$mdir" -- --mirror >"$TMPD/clone.out" 2>&1; then
            if [ -f "$AUDIT" ]; then
                env REPO_ROOT="$mdir" PDHA_REPO_NAME="$crepo" UNIFIED_DB_PATH="$UNIFIED_DB" \
                    bash "$AUDIT" >"$TMPD/audit.out" 2>"$TMPD/audit.err"
                arc=$?
            else
                arc=127
            fi
        fi
        rm -rf "$mdir"
        case "$arc" in
            0)   st="clean" ;;
            1)   st="findings"; AUDIT_FINDINGS=$((AUDIT_FINDINGS + 1)) ;;
            125) st="pending"; echo "  audit NOT run: mirror clone failed: $(head -c 200 "$TMPD/clone.out" | tr '\n' ' ')" ;;
            127) st="pending"; echo "  audit NOT run: audit script not found at ${AUDIT}" ;;
            *)   st="pending"; echo "  audit did not complete (rc=${arc}): $(head -c 200 "$TMPD/audit.err" | tr '\n' ' ')" ;;
        esac
        [ "$st" = "pending" ] && N_PENDING_LEFT=$((N_PENDING_LEFT + 1))
        echo "  audit result for ${crepo}: ${st} (rc=${arc})"
        duckdb -init /dev/null -bail "$UNIFIED_DB" -c "UPDATE repo_visibility_changes SET audit_status = '${st}', audited_at = current_timestamp, audit_rc = ${arc} WHERE id = '${cid}'" >/dev/null 2>"$TMPD/dberr" \
            || indeterminate "could not record the audit result for ${crepo} ($(head -c 200 "$TMPD/dberr" | tr '\n' ' '))"
    done < "$TMPD/pending.txt"

    # ── 5. Verdict ───────────────────────────────────────────────────────────
    if [ "$N_NEW" -gt 0 ] || [ "$N_PENDING_LEFT" -gt 0 ] || [ "$AUDIT_FINDINGS" -gt 0 ]; then
        {
            echo ""
            echo "repo_visibility_diff: ${N_NEW} new public repo finding(s), ${AUDIT_FINDINGS} audit(s) with findings, ${N_PENDING_LEFT} audit(s) still pending (exit 1)."
            echo "This does NOT auto-remediate. A repo that became public outside Claude may expose personal data;"
            echo "decide: make it private again (reversible) or review the audit findings (see private_data_history_audit.sh)."
        } >&2
        log_line "repos=${N_REPOS} public=${N_PUBLIC} new_findings=${N_NEW} audit_findings=${AUDIT_FINDINGS} audit_pending=${N_PENDING_LEFT} status=findings rc=1"
        hk_run_end "ok" "$N_NEW"
        notify "repo_visibility_diff" "${N_NEW} repo(s) newly public; ${N_PENDING_LEFT} audit(s) pending; ${AUDIT_FINDINGS} with findings"
        exit 1
    fi
    log_line "repos=${N_REPOS} public=${N_PUBLIC} new_findings=0 audit_findings=0 audit_pending=0 status=no_change rc=0"
    hk_run_end "ok" "0"
    exit 0
}

# ---------------------------------------------------------------------------
# --selftest
# ---------------------------------------------------------------------------
run_selftest() {
    local pass=0 total=0 sb DB SELF
    _check() { total=$((total + 1)); if [ "$1" = "0" ]; then pass=$((pass + 1)); echo "PASS  $2"; else echo "FAIL  $2"; fi; }
    _expect_rc() { if [ "$2" = "$1" ]; then _check 0 "$3 (rc=$2)"; else _check 1 "$3 (expected rc=$1, got rc=$2)"; fi; }
    _expect_eq() { if [ "$2" = "$1" ]; then _check 0 "$3 (=$2)"; else _check 1 "$3 (expected '$1', got '$2')"; fi; }

    if ! command -v duckdb >/dev/null 2>&1; then
        echo "INDETERMINATE: duckdb not on PATH -- selftest cannot run"
        exit 3
    fi

    sb="$(mktemp -d "${TMPDIR:-/tmp}/repo_vis_selftest.XXXXXX")"
    trap 'rm -rf "$sb"' EXIT
    mkdir -p "$sb/home" "$sb/stub"
    SELF="${BASH_SOURCE[0]:-$0}"
    case "$SELF" in /*) : ;; *) SELF="$(pwd)/$SELF" ;; esac
    DB="$sb/unified.duckdb"
    if duckdb -init /dev/null "$DB" < "$SCHEMA_SQL" >"$sb/schema.out" 2>&1; then
        _check 0 "housekeeping_schema_init.sql applies to a fresh sandbox DB (creates the snapshot tables)"
    else
        _check 1 "housekeeping_schema_init.sql failed to apply: $(head -3 "$sb/schema.out")"
    fi

    # Stub gh: behaviour from files in $STUB_DIR.
    cat > "$sb/gh_stub.sh" <<'EOF'
#!/usr/bin/env bash
d="$STUB_DIR"
echo "$*" >> "$d/gh_calls"
if [ -f "$d/fail_all" ]; then echo "gh: HTTP 502 Bad Gateway" >&2; exit 1; fi
case "$1 $2" in
  "api user")       cat "$d/login" ;;
  "api user/orgs")  [ -f "$d/fail_orgs" ] && { echo "gh: HTTP 500" >&2; exit 1; }; cat "$d/orgs" ;;
  "repo list")
    o="$3"
    [ -f "$d/fail_owner_$o" ] && { echo "gh: HTTP 403 rate limit" >&2; exit 1; }
    f="$d/repos_$o.tsv"; [ -f "$f" ] && cat "$f" ;;
  "repo clone")
    [ -f "$d/fail_clone" ] && { echo "fatal: repository not found" >&2; exit 128; }
    git init -q --bare "$4" ;;
  *) echo "gh stub: unexpected: $*" >&2; exit 99 ;;
esac
EOF
    cat > "$sb/audit_stub.sh" <<'EOF'
#!/usr/bin/env bash
d="$STUB_DIR"
[ -d "$REPO_ROOT" ] && dirstate=dir || dirstate=nodir
echo "$PDHA_REPO_NAME $dirstate" >> "$d/audit_calls"
[ -f "$d/audit_rc" ] && exit "$(cat "$d/audit_rc")"
exit 0
EOF
    cat > "$sb/osa_stub.sh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/osa_calls"
EOF
    chmod +x "$sb/gh_stub.sh" "$sb/audit_stub.sh" "$sb/osa_stub.sh"
    local st="$sb/stub"
    echo "tester" > "$st/login"

    cnt() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
    q() { duckdb -init /dev/null -csv -noheader "$DB" -c "$1" 2>&1; }
    # set_repo_rows OWNER ROW...   (each ROW "name|VIS|created")
    set_rows() {
        local o="$1" r; shift
        : > "$st/repos_$o.tsv"
        for r in "$@"; do
            printf '%s\t%s\t%s\n' "$(echo "$r" | cut -d'|' -f1)" "$(echo "$r" | cut -d'|' -f2)" "$(echo "$r" | cut -d'|' -f3)" >> "$st/repos_$o.tsv"
        done
    }
    # run_vd [script] ARGS... ; sets $vrc, $sb/out, $sb/err
    run_vd() {
        local script="$SELF"
        if [ "${1:-}" = "--script" ]; then script="$2"; shift 2; fi
        env HOME="$sb/home" SKIP_CRON_PULL=1 GH_BIN="$sb/gh_stub.sh" VD_AUDIT_CMD="$sb/audit_stub.sh" \
            OSASCRIPT_BIN="$sb/osa_stub.sh" UNIFIED_DB_PATH="$DB" STUB_DIR="$st" \
            bash "$script" "$@" >"$sb/out" 2>"$sb/err"
        vrc=$?
    }
    local A='2024-01-01T00:00:00Z' B='2024-02-01T00:00:00Z' G='2024-03-01T00:00:00Z'

    # 1: first run -> BASELINE, exit 0, loud, no audit, no alert
    : > "$st/orgs"; echo "acme" > "$st/orgs"
    set_rows tester "tester/alpha|PUBLIC|$A" "tester/beta|PRIVATE|$B"
    set_rows acme "acme/gamma|PRIVATE|$G"
    run_vd
    _expect_rc 0 "$vrc" "first run (no previous snapshot) exits 0"
    _check "$(grep -q 'BASELINE' "$sb/out" && echo 0 || echo 1)" "first run is loudly labelled BASELINE on stdout"
    _expect_eq 3 "$(q "SELECT count(*) FROM repo_visibility_snapshots")" "baseline stored one snapshot row per repo (user + org)"
    _expect_eq 0 "$(q "SELECT count(*) FROM repo_visibility_changes")" "baseline records no change"
    _expect_eq 0 "$(cnt "$st/audit_calls")" "baseline triggers no audit"
    _expect_eq 0 "$(cnt "$st/osa_calls")" "baseline raises no notification"
    _check "$(grep -q 'status=baseline' "$sb/home/.claude/logs/repo_visibility_diff.log" && echo 0 || echo 1)" "baseline logged with status=baseline"
    _expect_eq ok "$(q "SELECT status FROM housekeeping_runs WHERE task='repo_visibility_diff' ORDER BY started_at DESC LIMIT 1")" "baseline heartbeat status ok"
    _check "$(grep -q 'orgs' "$st/gh_calls" && echo 0 || echo 1)" "orgs the user belongs to are enumerated (gh api user/orgs)"
    _check "$(grep -q 'repo list acme' "$st/gh_calls" && echo 0 || echo 1)" "the org's repos are listed too"

    # 2: no change -> 0, no audit, no alert
    run_vd
    _expect_rc 0 "$vrc" "second run, nothing changed, exits 0"
    _expect_eq 6 "$(q "SELECT count(*) FROM repo_visibility_snapshots")" "a second snapshot was stored"
    _expect_eq 0 "$(q "SELECT count(*) FROM repo_visibility_changes")" "no change recorded"
    _expect_eq 0 "$(cnt "$st/audit_calls")" "no audit when nothing changed"
    _expect_eq 0 "$(cnt "$st/osa_calls")" "no notification when nothing changed"
    _check "$(grep -q 'status=no_change' "$sb/home/.claude/logs/repo_visibility_diff.log" && echo 0 || echo 1)" "log carries status=no_change"

    # 3: a private repo becomes public -> exit 1, audit on a mirror, alert
    set_rows tester "tester/alpha|PUBLIC|$A" "tester/beta|PUBLIC|$B"
    run_vd
    _expect_rc 1 "$vrc" "private -> public exits 1"
    _check "$(grep -q 'FINDING became_public tester/beta' "$sb/out" && echo 0 || echo 1)" "the finding names the repo and change type"
    _expect_eq "became_public|PRIVATE|clean|0" "$(q "SELECT change_type||'|'||prev_visibility||'|'||audit_status||'|'||audit_rc FROM repo_visibility_changes WHERE repo='tester/beta'")" "change row: became_public, prev PRIVATE, audit clean rc 0"
    _expect_eq "tester/beta dir" "$(cat "$st/audit_calls")" "audit invoked once, for that repo, on an existing mirror directory"
    _expect_eq 1 "$(cnt "$st/osa_calls")" "a macOS notification was raised"
    _expect_eq 1 "$(q "SELECT rows_written FROM housekeeping_runs WHERE task='repo_visibility_diff' ORDER BY started_at DESC LIMIT 1")" "heartbeat rows_written = findings (1)"

    # 4: unchanged afterwards -> the finding is reported once, not daily
    run_vd
    _expect_rc 0 "$vrc" "next run with the repo still public and audited exits 0"
    _expect_eq 1 "$(cnt "$st/audit_calls")" "no repeat audit"
    _expect_eq 1 "$(q "SELECT count(*) FROM repo_visibility_changes")" "no duplicate change row"

    # 5: new public repo (user + org), new private repo, public -> private
    set_rows tester "tester/alpha|PRIVATE|$A" "tester/beta|PUBLIC|$B" "tester/delta|PUBLIC|2024-04-01T00:00:00Z" "tester/eps|PRIVATE|2024-05-01T00:00:00Z"
    set_rows acme "acme/gamma|PRIVATE|$G" "acme/zeta|PUBLIC|2024-06-01T00:00:00Z"
    run_vd
    _expect_rc 1 "$vrc" "new public repos exit 1"
    _expect_eq "new_public|NULL" "$(q "SELECT change_type||'|'||coalesce(prev_visibility,'NULL') FROM repo_visibility_changes WHERE repo='tester/delta'")" "user's new public repo: new_public, no previous visibility"
    _expect_eq "new_public" "$(q "SELECT change_type FROM repo_visibility_changes WHERE repo='acme/zeta'")" "org's new public repo is caught too"
    _expect_eq 0 "$(q "SELECT count(*) FROM repo_visibility_changes WHERE repo IN ('tester/eps','tester/alpha')")" "new private repo and public->private are NOT findings"
    _expect_eq 3 "$(cnt "$st/audit_calls")" "audit ran for exactly the two new findings (3 calls total)"

    # 6: audit reports findings
    set_rows acme "acme/gamma|PUBLIC|$G" "acme/zeta|PUBLIC|2024-06-01T00:00:00Z"
    echo 1 > "$st/audit_rc"
    run_vd
    _expect_rc 1 "$vrc" "audit exit 1 (findings) exits 1"
    _expect_eq "findings|1" "$(q "SELECT audit_status||'|'||audit_rc FROM repo_visibility_changes WHERE repo='acme/gamma'")" "change row: audit_status findings, rc 1"
    echo 0 > "$st/audit_rc"

    # 7: audit INDETERMINATE -> pending, still exit 1; 8: retried next run
    set_rows tester "tester/alpha|PRIVATE|$A" "tester/beta|PUBLIC|$B" "tester/delta|PUBLIC|2024-04-01T00:00:00Z" "tester/eps|PUBLIC|2024-05-01T00:00:00Z"
    echo 3 > "$st/audit_rc"
    run_vd
    _expect_rc 1 "$vrc" "audit INDETERMINATE (3) exits 1, never clean"
    _expect_eq "pending|3" "$(q "SELECT audit_status||'|'||audit_rc FROM repo_visibility_changes WHERE repo='tester/eps'")" "audit_status stays pending, rc 3 recorded"
    before="$(cnt "$st/audit_calls")"
    run_vd
    _expect_rc 1 "$vrc" "a still-pending audit keeps the next run at exit 1 (no change in the listing)"
    _expect_eq $((before + 1)) "$(cnt "$st/audit_calls")" "the pending audit is retried on the next run"
    echo 0 > "$st/audit_rc"
    run_vd
    _expect_rc 0 "$vrc" "retry succeeds -> audit clean -> exit 0"
    _expect_eq "clean|0" "$(q "SELECT audit_status||'|'||audit_rc FROM repo_visibility_changes WHERE repo='tester/eps'")" "pending finding resolved to clean"

    # 9: repo recreated under the same name with a different created_at, public
    set_rows tester "tester/alpha|PUBLIC|2025-01-01T00:00:00Z" "tester/beta|PUBLIC|$B" "tester/delta|PUBLIC|2024-04-01T00:00:00Z" "tester/eps|PUBLIC|2024-05-01T00:00:00Z"
    run_vd
    _expect_rc 1 "$vrc" "a public repo recreated under an old name (new created_at) exits 1"
    _expect_eq "new_public" "$(q "SELECT change_type FROM repo_visibility_changes WHERE repo='tester/alpha'")" "recreated repo is new_public, not matched to its old row"

    # 10: mirror clone failure -> pending (125), exit 1; recovers
    set_rows tester "tester/alpha|PUBLIC|2025-01-01T00:00:00Z" "tester/beta|PUBLIC|$B" "tester/delta|PUBLIC|2024-04-01T00:00:00Z" "tester/eps|PUBLIC|2024-05-01T00:00:00Z" "tester/newpub|PUBLIC|2025-02-01T00:00:00Z"
    : > "$st/fail_clone"
    run_vd
    _expect_rc 1 "$vrc" "mirror clone failure exits 1"
    _expect_eq "pending|125" "$(q "SELECT audit_status||'|'||audit_rc FROM repo_visibility_changes WHERE repo='tester/newpub'")" "clone failure: pending, rc 125 (audit never ran)"
    rm -f "$st/fail_clone"
    run_vd
    _expect_rc 0 "$vrc" "after the clone works the retry completes -> exit 0"

    # 11: INDETERMINATE paths, each exactly 3, none touching the snapshot table
    snaps="$(q "SELECT count(*) FROM repo_visibility_snapshots")"
    osa_before="$(cnt "$st/osa_calls")"
    : > "$st/fail_all"
    run_vd
    _expect_rc 3 "$vrc" "gh API failure is INDETERMINATE"
    _check "$(grep -q 'INDETERMINATE' "$sb/err" && echo 0 || echo 1)" "the failure says INDETERMINATE and why"
    _expect_eq "$snaps" "$(q "SELECT count(*) FROM repo_visibility_snapshots")" "a failed run writes no snapshot"
    _expect_eq partial "$(q "SELECT status FROM housekeeping_runs WHERE task='repo_visibility_diff' ORDER BY started_at DESC LIMIT 1")" "failed run heartbeat is 'partial'"
    _expect_eq $((osa_before + 1)) "$(cnt "$st/osa_calls")" "INDETERMINATE raises a notification too"
    rm -f "$st/fail_all"
    : > "$st/fail_orgs"; run_vd; _expect_rc 3 "$vrc" "org enumeration failure is INDETERMINATE"; rm -f "$st/fail_orgs"
    : > "$st/fail_owner_acme"; run_vd; _expect_rc 3 "$vrc" "one org's listing failing is INDETERMINATE (no partial pass)"; rm -f "$st/fail_owner_acme"
    cp "$st/repos_tester.tsv" "$st/repos_tester.bak"
    : > "$st/repos_tester.tsv"; run_vd; _expect_rc 3 "$vrc" "an empty listing for the owner is INDETERMINATE, not 'no repos'"
    printf 'tester/weird\tSECRET\t2024-01-01T00:00:00Z\n' >> "$st/repos_tester.bak"
    cp "$st/repos_tester.bak" "$st/repos_tester.tsv"; run_vd; _expect_rc 3 "$vrc" "an unknown visibility value is INDETERMINATE"
    printf 'bad name with spaces\tPUBLIC\t2024-01-01T00:00:00Z\n' > "$st/repos_tester.tsv"; run_vd; _expect_rc 3 "$vrc" "a malformed repo name is INDETERMINATE"
    awk 'BEGIN{for(i=1;i<=1000;i++) printf "tester/r%d\tPRIVATE\t2024-01-01T00:00:00Z\n", i}' > "$st/repos_tester.tsv"
    run_vd; _expect_rc 3 "$vrc" "a listing at the --limit cap (possibly truncated) is INDETERMINATE"
    _expect_eq "$snaps" "$(q "SELECT count(*) FROM repo_visibility_snapshots")" "none of the INDETERMINATE runs wrote a snapshot"
    # restore a valid listing
    set_rows tester "tester/alpha|PUBLIC|2025-01-01T00:00:00Z" "tester/beta|PUBLIC|$B" "tester/delta|PUBLIC|2024-04-01T00:00:00Z" "tester/eps|PUBLIC|2024-05-01T00:00:00Z" "tester/newpub|PUBLIC|2025-02-01T00:00:00Z"
    run_vd
    _expect_rc 0 "$vrc" "after the API recovers the run is a clean exit 0 (no snapshot gap hides a change)"

    # 12: DB problems are INDETERMINATE
    env HOME="$sb/home" SKIP_CRON_PULL=1 GH_BIN="$sb/gh_stub.sh" VD_AUDIT_CMD="$sb/audit_stub.sh" OSASCRIPT_BIN="$sb/osa_stub.sh" \
        UNIFIED_DB_PATH="$sb/no_such.duckdb" STUB_DIR="$st" bash "$SELF" >"$sb/out" 2>"$sb/err"
    _expect_rc 3 "$?" "snapshot DB missing is INDETERMINATE"
    duckdb -init /dev/null "$sb/notable.duckdb" -c "CREATE TABLE housekeeping_runs (id TEXT PRIMARY KEY, task TEXT NOT NULL, source_script TEXT NOT NULL, started_at TIMESTAMPTZ NOT NULL, ended_at TIMESTAMPTZ, status TEXT, rows_written INTEGER);" >/dev/null 2>&1
    env HOME="$sb/home" SKIP_CRON_PULL=1 GH_BIN="$sb/gh_stub.sh" VD_AUDIT_CMD="$sb/audit_stub.sh" OSASCRIPT_BIN="$sb/osa_stub.sh" \
        UNIFIED_DB_PATH="$sb/notable.duckdb" STUB_DIR="$st" bash "$SELF" >"$sb/out" 2>"$sb/err"
    _expect_rc 3 "$?" "snapshot tables missing is INDETERMINATE"
    env HOME="$sb/home" SKIP_CRON_PULL=1 GH_BIN="$sb/no_such_gh" VD_AUDIT_CMD="$sb/audit_stub.sh" OSASCRIPT_BIN="$sb/osa_stub.sh" \
        UNIFIED_DB_PATH="$DB" STUB_DIR="$st" bash "$SELF" >"$sb/out" 2>"$sb/err"
    _expect_rc 3 "$?" "gh missing is INDETERMINATE"

    # 13: usage error
    run_vd --no-such-flag
    _expect_rc 2 "$vrc" "unknown argument is a usage error"

    # 14: FALSIFICATION. A copy of this script whose 'became public' filter is
    # broken must MISS the became-public case. Proves the became-public checks
    # above can go red and are not satisfied by a constant exit code.
    sed "s/c.visibility = 'PUBLIC' AND/c.visibility = 'NO_SUCH' AND/" "$SELF" > "$sb/mutant.sh"
    if cmp -s "$SELF" "$sb/mutant.sh"; then
        _check 1 "falsification: mutation did not change the script (check is vacuous)"
    else
        _check 0 "falsification: mutated copy differs from the real script"
    fi
    DB="$sb/fals.duckdb"
    duckdb -init /dev/null "$DB" < "$SCHEMA_SQL" >/dev/null 2>&1
    echo "acme" > "$st/orgs"
    set_rows tester "tester/alpha|PUBLIC|$A" "tester/beta|PRIVATE|$B"
    set_rows acme "acme/gamma|PRIVATE|$G"
    run_vd --script "$sb/mutant.sh"
    set_rows tester "tester/alpha|PUBLIC|$A" "tester/beta|PUBLIC|$B"
    run_vd --script "$sb/mutant.sh"
    _expect_rc 0 "$vrc" "falsification: the broken filter misses private -> public (exit 0, the check CAN go red)"
    DB="$sb/fals2.duckdb"
    duckdb -init /dev/null "$DB" < "$SCHEMA_SQL" >/dev/null 2>&1
    set_rows tester "tester/alpha|PUBLIC|$A" "tester/beta|PRIVATE|$B"
    run_vd
    set_rows tester "tester/alpha|PUBLIC|$A" "tester/beta|PUBLIC|$B"
    run_vd
    _expect_rc 1 "$vrc" "falsification control: the real script on the identical sequence exits 1"

    echo ""
    echo "repo_visibility_diff selftest: $pass/$total PASS"
    [ "$pass" -eq "$total" ] && exit 0
    exit 1
}

case "${1:-}" in
    "") ;;
    --selftest) run_selftest ;;
    -h|--help) echo "Usage: repo_visibility_diff.sh [--selftest]"; exit 0 ;;
    *) echo "repo_visibility_diff: unknown argument: $1" >&2; exit 2 ;;
esac

# One line: bash must not read past this point of the file (the auto-pull may
# fast-forward this very script while it runs).
run_main; exit $?
