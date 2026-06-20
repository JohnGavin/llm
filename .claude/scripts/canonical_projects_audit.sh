#!/usr/bin/env bash
# canonical_projects_audit.sh — audit project-column values in unified.duckdb
# Closes llm#535. References llm#528 (design), llm#540 (migration), llm#652 (ephemeral bucket).
#
# Classifies every distinct value in source columns as:
#   FIXTURE   — known test / fixture slug matching the fixture regex
#   EPHEMERAL — runtime-generated token (agent worktree, session id, branch slug)
#   CANONICAL — present in canonical_projects.slug or canonical_project_aliases.alias
#   UNKNOWN   — none of the above (the actionable set we care about)
#
# Source columns audited:
#   roborev_review_lifecycle.repo
#   roborev_finding_lineage_summary.repo  (skipped if table absent)
#   sessions.project                       (skipped if table absent)
#
# Usage:
#   canonical_projects_audit.sh           # --quiet mode (default)
#   canonical_projects_audit.sh --quiet   # one compact line; silent if fully clean
#   canonical_projects_audit.sh --verbose # per-bucket detail to stdout
#   canonical_projects_audit.sh --selftest # assertions then exit
#
# Fail-open contract: never exits non-zero in normal operation; only selftest
# may exit non-zero.  session_init.sh wraps with "|| true" regardless.

set -uo pipefail

export PATH="/nix/var/nix/profiles/default/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIVE_DB="${CLAUDE_LOGS_DIR:-$HOME/.claude/logs}/unified.duckdb"
NIX_DEFAULT="$REPO_ROOT/default.nix"

LOG="${CLAUDE_LOGS_DIR:-$HOME/.claude/logs}/canonical_projects_audit.log"
_log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [canonical_projects_audit] $*" >> "$LOG"; }

# ── mode -------------------------------------------------------------------
MODE="quiet"
case "${1:-}" in
    --verbose)  MODE="verbose"  ;;
    --quiet)    MODE="quiet"    ;;
    --selftest) MODE="selftest" ;;
esac

# ── duckdb runner -----------------------------------------------------------
_duck_run() {
    # Usage: _duck_run <db> <sql>
    # Pipes SQL via stdin to avoid shell quoting issues inside nix-shell --run.
    # Filters out DuckDB startup noise: run-time banners, extension-load lines,
    # memory lines, db-open path lines, and blank lines.
    local db="$1" sql="$2"
    local raw=""
    if command -v duckdb >/dev/null 2>&1; then
        raw="$(printf '%s\n' "$sql" | duckdb -noheader -list "$db" 2>/dev/null)" || true
    elif [ -f "$NIX_DEFAULT" ] && command -v nix-shell >/dev/null 2>&1; then
        raw="$(printf '%s\n' "$sql" | nix-shell "$NIX_DEFAULT" --run "duckdb -noheader -list \"$db\"" 2>/dev/null)" || true
    else
        _log "duckdb not found and no nix-shell fallback available"
        return 0
    fi
    printf '%s\n' "$raw" | awk '
        /^Run Time/              { next }
        /^loaded / && /;$/       { next }
        /^memory:/               { next }
        /^[a-zA-Z0-9_.+-]+: \// { next }
        /^$/                     { next }
        { print }
    '
}

# Scalar variant — returns only the last non-empty line (for COUNT(*) etc.)
_duck_scalar() {
    _duck_run "$1" "$2" | tail -1
}

# ── fixture regex ----------------------------------------------------------
# Values matching this pattern are test/fixture artefacts, not real projects.
# Maintained in sync with llm#528 design doc.
_is_fixture() {
    local v="$1"
    case "$v" in
        config_digest_git_fixture_*) return 0 ;;
        kb_fixture_*) return 0 ;;
        kb_e2e_test*) return 0 ;;
        kb_debug_test*) return 0 ;;
        kb_*_fixture*) return 0 ;;
        roborev_pmhook_test_*) return 0 ;;
        testrepo_*) return 0 ;;
        tmp.*) return 0 ;;
        tmprepo_*) return 0 ;;
        tlang-clone*) return 0 ;;
        test_repo*) return 0 ;;
        repo|repo[0-9]*|repo_*) return 0 ;;
    esac
    return 1
}

# ── ephemeral regex --------------------------------------------------------
# Values matching this pattern are runtime-generated tokens (agent worktrees,
# session IDs, branch slugs) — not real projects, not test fixtures.
# Added llm#652 to cut UNKNOWN noise to genuine signal.
_is_ephemeral() {
    local v="$1"
    # agent-<hex12+> — harness agent worktree dirs
    case "$v" in
        agent-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*)
            return 0 ;;
    esac
    # worktree-<digits> and roborev-worktree-<digits>
    case "$v" in
        worktree-[0-9]*) return 0 ;;
        roborev-worktree-[0-9]*) return 0 ;;
    esac
    # cc-YYYYMMDD-HHMMSS session IDs
    case "$v" in
        cc-2026[0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]*) return 0 ;;
        cc-2027[0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]*) return 0 ;;
        cc-2028[0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]*) return 0 ;;
    esac
    # <proj>-feat-cc-… branch session dirs (e.g. llm-feat-cc-20260601-120000)
    case "$v" in
        *-feat-cc-20[0-9][0-9]*) return 0 ;;
    esac
    # <proj>-feat-<slug> and <proj>-fix-<slug> branch worktree dirs
    case "$v" in
        *-feat-[a-z0-9]*) return 0 ;;
        *-fix-[a-z0-9]*) return 0 ;;
        *-sonnet) return 0 ;;
    esac
    # ^<digits>- issue/PR branch slugs (e.g. 652-canonical-audit)
    case "$v" in
        [0-9]*-*) return 0 ;;
    esac
    # issue-<digits>- prefix
    case "$v" in
        issue-[0-9]*-*) return 0 ;;
    esac
    # selftest artefacts the fixture regex doesn't catch
    case "$v" in
        *_selftest*) return 0 ;;
        branch_harvest_selftest*) return 0 ;;
        kb_digest_selftest_*) return 0 ;;
    esac
    return 1
}

# ── selftest mode -----------------------------------------------------------
if [ "$MODE" = "selftest" ]; then
    FIXTURE_DB="/tmp/canonical_projects_audit_test_$$.duckdb"
    PASS=0; FAIL=0

    _assert_eq() {
        local desc="$1" expected="$2" actual="$3"
        if [ "$actual" = "$expected" ]; then
            echo "  PASS: $desc"
            PASS=$((PASS+1))
        else
            echo "  FAIL: $desc — expected '$expected', got '$actual'"
            FAIL=$((FAIL+1))
        fi
    }

    echo "canonical_projects_audit selftest — fixture DB: $FIXTURE_DB"

    # Set up fixture DB
    _duck_run "$FIXTURE_DB" "
        CREATE TABLE canonical_projects (slug VARCHAR PRIMARY KEY);
        CREATE TABLE canonical_project_aliases (slug VARCHAR, alias VARCHAR, PRIMARY KEY (slug, alias));
        CREATE TABLE roborev_review_lifecycle (repo VARCHAR);
        INSERT INTO canonical_projects VALUES ('llm'), ('mycare'), ('irishbuoys');
        INSERT INTO canonical_project_aliases VALUES ('coMMpass', 'commpass');
        INSERT INTO roborev_review_lifecycle VALUES
            ('llm'), ('mycare'),
            ('config_digest_git_fixture_abc123'),
            ('roborev_pmhook_test_x'),
            ('repo1'),
            ('hello_t');
    " > /dev/null 2>&1

    # ── original fixture tests (preserved) ------------------------------------
    # Test 1: fixture regex — config_digest_git_fixture_
    _is_fixture "config_digest_git_fixture_abc123" && _r="FIXTURE" || _r="OTHER"
    _assert_eq "config_digest_git_fixture_ classifies as FIXTURE" "FIXTURE" "$_r"

    # Test 2: fixture regex — roborev_pmhook_test_
    _is_fixture "roborev_pmhook_test_x" && _r="FIXTURE" || _r="OTHER"
    _assert_eq "roborev_pmhook_test_ classifies as FIXTURE" "FIXTURE" "$_r"

    # Test 3: fixture regex — repo1
    _is_fixture "repo1" && _r="FIXTURE" || _r="OTHER"
    _assert_eq "repo1 classifies as FIXTURE" "FIXTURE" "$_r"

    # Test 4: known canonical slug not classified as fixture
    _is_fixture "llm" && _r="FIXTURE" || _r="NOT_FIXTURE"
    _assert_eq "llm does not classify as FIXTURE" "NOT_FIXTURE" "$_r"

    # Test 5: canonical_projects count readable
    _count=$(_duck_scalar "$FIXTURE_DB" "SELECT COUNT(*) FROM canonical_projects;")
    _assert_eq "canonical_projects has 3 rows" "3" "$_count"

    # Test 6: hello_t is UNKNOWN (not fixture, not canonical, not ephemeral)
    _is_fixture "hello_t" && _fi="y" || _fi="n"
    _is_ephemeral "hello_t" && _ep="y" || _ep="n"
    _ca=$(_duck_scalar "$FIXTURE_DB" "SELECT COUNT(*) FROM canonical_projects WHERE slug='hello_t';")
    _al=$(_duck_scalar "$FIXTURE_DB" "SELECT COUNT(*) FROM canonical_project_aliases WHERE alias='hello_t';")
    if [ "$_fi" = "n" ] && [ "$_ep" = "n" ] && [ "$_ca" = "0" ] && [ "$_al" = "0" ]; then _r="UNKNOWN"; else _r="OTHER"; fi
    _assert_eq "hello_t classifies as UNKNOWN" "UNKNOWN" "$_r"

    # ── new ephemeral tests (llm#652) -----------------------------------------
    # Test 7: agent worktree hash
    _is_ephemeral "agent-a095a135bf5b" && _r="EPHEMERAL" || _r="OTHER"
    _assert_eq "agent-<hex12> classifies as EPHEMERAL" "EPHEMERAL" "$_r"

    # Test 8: worktree-<digits>
    _is_ephemeral "worktree-20260617" && _r="EPHEMERAL" || _r="OTHER"
    _assert_eq "worktree-<digits> classifies as EPHEMERAL" "EPHEMERAL" "$_r"

    # Test 9: roborev-worktree-<digits>
    _is_ephemeral "roborev-worktree-1234" && _r="EPHEMERAL" || _r="OTHER"
    _assert_eq "roborev-worktree-<digits> classifies as EPHEMERAL" "EPHEMERAL" "$_r"

    # Test 10: cc-YYYYMMDD-HHMMSS session ID
    _is_ephemeral "cc-20260617-114959" && _r="EPHEMERAL" || _r="OTHER"
    _assert_eq "cc-20260617-114959 classifies as EPHEMERAL" "EPHEMERAL" "$_r"

    # Test 11: <proj>-feat-cc-… branch worktree dir
    _is_ephemeral "llm-feat-cc-20260601-120000" && _r="EPHEMERAL" || _r="OTHER"
    _assert_eq "<proj>-feat-cc-... classifies as EPHEMERAL" "EPHEMERAL" "$_r"

    # Test 12: <proj>-sonnet branch form
    _is_ephemeral "mycare-sonnet" && _r="EPHEMERAL" || _r="OTHER"
    _assert_eq "<proj>-sonnet classifies as EPHEMERAL" "EPHEMERAL" "$_r"

    # Test 13: ^<digits>- issue slug
    _is_ephemeral "652-canonical-audit" && _r="EPHEMERAL" || _r="OTHER"
    _assert_eq "652-canonical-audit classifies as EPHEMERAL" "EPHEMERAL" "$_r"

    # Test 14: issue-<digits>- prefix
    _is_ephemeral "issue-652-canonical-audit" && _r="EPHEMERAL" || _r="OTHER"
    _assert_eq "issue-<digits>-<slug> classifies as EPHEMERAL" "EPHEMERAL" "$_r"

    # Test 15: *_selftest* not caught by _is_fixture
    _is_fixture "branch_harvest_selftest_abc" && _fi="y" || _fi="n"
    _is_ephemeral "branch_harvest_selftest_abc" && _r="EPHEMERAL" || _r="OTHER"
    _assert_eq "branch_harvest_selftest_abc: _is_fixture=n, _is_ephemeral=EPHEMERAL" "EPHEMERAL" "$_r"

    # Test 16: real project slug not classified as ephemeral
    _is_ephemeral "irishbuoys" && _r="EPHEMERAL" || _r="NOT_EPHEMERAL"
    _assert_eq "irishbuoys does not classify as EPHEMERAL" "NOT_EPHEMERAL" "$_r"

    # Test 17: real project slug not classified as fixture
    _is_fixture "irishbuoys" && _r="FIXTURE" || _r="NOT_FIXTURE"
    _assert_eq "irishbuoys does not classify as FIXTURE" "NOT_FIXTURE" "$_r"

    rm -f "$FIXTURE_DB"
    echo ""
    echo "selftest: $((PASS+FAIL)) tests — PASS=$PASS FAIL=$FAIL"
    [ "$FAIL" -eq 0 ] && exit 0 || exit 1
fi

# ── guard: DB must exist ---------------------------------------------------
if [ ! -f "$LIVE_DB" ]; then
    [ "$MODE" = "verbose" ] && echo "canonical-projects-audit: unified.duckdb not found — skipped"
    exit 0
fi

# ── load canonical slug set (one-shot query) --------------------------------
_canon_slugs=$(_duck_run "$LIVE_DB" "SELECT slug FROM canonical_projects UNION SELECT alias FROM canonical_project_aliases ORDER BY 1;") || _canon_slugs=""
_canon_count=$(_duck_scalar "$LIVE_DB" "SELECT COUNT(*) FROM canonical_projects;") || _canon_count="?"

_is_canonical() {
    printf '%s\n' "$_canon_slugs" | grep -qxF "$1" 2>/dev/null
}

# ── audit one table.column -------------------------------------------------
# Returns 5 lines: n_canon, n_fixture, n_ephemeral, n_unknown, presence flag.
# Prints per-column summary to stdout in verbose mode.
_audit_column() {
    local tbl="$1" col="$2"

    # Check table exists
    local tbl_exists
    tbl_exists=$(_duck_scalar "$LIVE_DB" "SELECT COUNT(*) FROM information_schema.tables WHERE table_name='${tbl}';") || tbl_exists="0"
    if [ "${tbl_exists:-0}" = "0" ]; then
        _log "table $tbl not found — skipping"
        printf "0\n0\n0\n0\nabsent\n"
        return 0
    fi

    local vals
    vals=$(_duck_run "$LIVE_DB" "SELECT DISTINCT ${col} FROM ${tbl} WHERE ${col} IS NOT NULL ORDER BY ${col};") || vals=""

    local n_canon=0 n_fixture=0 n_ephemeral=0 n_unknown=0
    local unknown_list=""
    while IFS= read -r v; do
        [ -z "$v" ] && continue
        if _is_fixture "$v"; then
            n_fixture=$((n_fixture+1))
        elif _is_ephemeral "$v"; then
            n_ephemeral=$((n_ephemeral+1))
        elif _is_canonical "$v"; then
            n_canon=$((n_canon+1))
        else
            n_unknown=$((n_unknown+1))
            unknown_list="${unknown_list:+$unknown_list, }$v"
        fi
    done <<< "$vals"

    if [ "$MODE" = "verbose" ]; then
        echo "  ${tbl}.${col}: CANONICAL=$n_canon FIXTURE=$n_fixture EPHEMERAL=$n_ephemeral UNKNOWN=$n_unknown" >&2
        if [ $n_unknown -gt 0 ]; then
            echo "    UNKNOWN: $unknown_list" >&2
        fi
    fi

    printf "%d\n%d\n%d\n%d\npresent\n" "$n_canon" "$n_fixture" "$n_ephemeral" "$n_unknown"
}

# ── accumulate totals across all source columns ----------------------------
_total_canon=0
_total_fixture=0
_total_ephemeral=0
_total_unknown=0
_detail_parts=""

# Helper: parse _audit_column output (now 5 lines) into named vars
_parse_result() {
    local result="$1" suffix="$2"
    local c f e u status
    c=$(printf '%s\n' "$result" | sed -n '1p')
    f=$(printf '%s\n' "$result" | sed -n '2p')
    e=$(printf '%s\n' "$result" | sed -n '3p')
    u=$(printf '%s\n' "$result" | sed -n '4p')
    status=$(printf '%s\n' "$result" | sed -n '5p')

    [ "$status" = "absent" ] && return 0

    _total_canon=$((_total_canon + ${c:-0}))
    _total_fixture=$((_total_fixture + ${f:-0}))
    _total_ephemeral=$((_total_ephemeral + ${e:-0}))
    _total_unknown=$((_total_unknown + ${u:-0}))

    if [ "${u:-0}" -gt 0 ]; then
        _detail_parts="${_detail_parts}${suffix}:${u:-0} "
    fi
}

_r1=$(_audit_column "roborev_review_lifecycle" "repo")
_parse_result "$_r1" "lifecycle.repo"

_r2=$(_audit_column "roborev_finding_lineage_summary" "repo")
_parse_result "$_r2" "lineage.repo"

_r3=$(_audit_column "sessions" "project")
_parse_result "$_r3" "sessions.project"

# ── emit output ------------------------------------------------------------
_log "audit: canon=$_total_canon fixture=$_total_fixture ephemeral=$_total_ephemeral unknown=$_total_unknown (canonical_projects=$_canon_count)"

if [ "$MODE" = "quiet" ]; then
    # Emit one compact line only when there are unknowns; silent if fully clean.
    if [ "${_total_unknown:-0}" -gt 0 ]; then
        echo "canonical-projects-audit: UNKNOWN=${_total_unknown} EPHEMERAL=${_total_ephemeral} CANONICAL=${_total_canon} FIXTURE=${_total_fixture} [${_detail_parts% }]"
    fi
elif [ "$MODE" = "verbose" ]; then
    echo "canonical-projects-audit: UNKNOWN=${_total_unknown} EPHEMERAL=${_total_ephemeral} CANONICAL=${_total_canon} FIXTURE=${_total_fixture} (canonical_projects in DB: ${_canon_count})"
fi

exit 0
