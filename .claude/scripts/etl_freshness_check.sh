#!/usr/bin/env bash
# etl_freshness_check.sh — ETL freshness alarm for unified.duckdb tables.
#
# Checks when each tracked source table was last written.  Reports GREEN /
# AMBER / RED / CRITICAL severity and exits accordingly.
#
# Usage:
#   etl_freshness_check.sh              # normal — prints compact summary
#   etl_freshness_check.sh --quiet      # one-line summary only (machine-parseable)
#   etl_freshness_check.sh --verbose    # full per-table report
#   etl_freshness_check.sh --list-tables # print tracked table set and exit 0
#   etl_freshness_check.sh --no-discover # skip auto-discovery of untracked stale tables
#   etl_freshness_check.sh --selftest   # run self-tests against fixture DBs
#
# Exit codes:
#   0 — all GREEN
#   1 — at least one AMBER (warning)
#   2 — at least one RED or CRITICAL (alarm)
#
# Env vars:
#   CLAUDE_ETL_FRESHNESS_CHECK=0  — skip entirely (session_init.sh opt-out)
#   ETL_FRESHNESS_DB              — override DB path (for testing)
#
# Phase 15a of session_init.sh. Called with:
#   timeout 5 .claude/scripts/etl_freshness_check.sh --quiet 2>/dev/null || true

set -uo pipefail

# ─── PATH (launchd / session_init may have a bare PATH) ──────────────────────
export PATH="/nix/var/nix/profiles/default/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

# ─── Paths ───────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NIX_DEFAULT="$(cd "${SCRIPT_DIR}/../.." 2>/dev/null && pwd)/default.nix"
DB="${ETL_FRESHNESS_DB:-${HOME}/.claude/logs/unified.duckdb}"

# ─── duckdb invocation ───────────────────────────────────────────────────────
# Prefer direct duckdb if available (fast; avoids nix-shell startup overhead).
# Fall back to nix-shell wrapper if duckdb is not in PATH but nix-shell + default.nix exist.
duck_run() {
    if command -v duckdb >/dev/null 2>&1; then
        duckdb "$@"
    elif command -v nix-shell >/dev/null 2>&1 && [[ -f "${NIX_DEFAULT}" ]]; then
        local q="" a
        for a in "$@"; do q+=" $(printf '%q' "$a")"; done
        nix-shell "${NIX_DEFAULT}" --run "duckdb${q}"
    else
        echo "etl-freshness: duckdb not found" >&2
        exit 0  # fail-open: no duckdb available → skip silently
    fi
}

# ─── Severity thresholds (seconds) ───────────────────────────────────────────
# GREEN:    latest row within 24h of now
# AMBER:    latest row 24h–7d old
# RED:      latest row > 7d old
# CRITICAL: table empty OR latest row > 30d old

THRESH_GREEN=86400        # 24 hours
THRESH_AMBER=604800       # 7 days
THRESH_RED=2592000        # 30 days

# ─── Table → timestamp column map ────────────────────────────────────────────
# Format: "table_name:ts_column[:rate_check]"
#   rate_check = "rate" triggers 7-day average rate AMBER check (< 5 rows/day)
TRACKED_TABLES=(
    # ── Core session infrastructure ────────────────────────────────────────
    "hook_events:fired_at:rate"
    "errors:logged_at"
    "agent_runs:started_at:rate"
    "sessions:started_at"
    "self_review_findings_stage1:detected_at"
    # ── Roborev pipeline — produced by com.claude.roborev-metrics-etl @ 02:00 daily
    "roborev_review_lifecycle:created_at:rate"
    "roborev_finding_lineage:created_at"
    "roborev_finding_lineage_summary:closed_at_last"
    "roborev_daily_metrics:etl_run_at"
    # ── Roborev event-driven (sparse; no rate check) ───────────────────────
    "roborev_threshold_changes:changed_at_utc:max_age=60d"
)

# ─── Severity colour codes (only when a terminal) ────────────────────────────
if [[ -t 1 ]]; then
    C_RED='\033[0;31m'
    C_AMBER='\033[0;33m'
    C_GREEN='\033[0;32m'
    C_RESET='\033[0m'
else
    C_RED='' C_AMBER='' C_GREEN='' C_RESET=''
fi

# ─── Argument parsing ─────────────────────────────────────────────────────────
MODE="normal"   # normal | quiet | verbose | selftest | list-tables
DISCOVER=1      # 1=auto-discover untracked stale tables; 0=skip

for arg in "$@"; do
    case "${arg}" in
        --quiet)        MODE="quiet" ;;
        --verbose)      MODE="verbose" ;;
        --selftest)     MODE="selftest" ;;
        --list-tables)  MODE="list-tables" ;;
        --no-discover)  DISCOVER=0 ;;
        *)
            echo "Usage: $0 [--quiet|--verbose|--selftest|--list-tables|--no-discover]" >&2
            exit 1
            ;;
    esac
done

# ─── Opt-out env var ─────────────────────────────────────────────────────────
if [[ "${CLAUDE_ETL_FRESHNESS_CHECK:-1}" == "0" ]]; then
    exit 0
fi

# ─── check_table: returns "SEVERITY:age_description:detail" ──────────────────
# Writes nothing to stdout (caller captures).
check_table() {
    local spec="$1"
    local table ts_col do_rate_check max_age_days
    table="${spec%%:*}"
    local rest="${spec#*:}"
    ts_col="${rest%%:*}"
    do_rate_check=""
    max_age_days=""
    if [[ "$rest" == *":rate" ]]; then
        do_rate_check="1"
    fi
    # Per-table max-age override: ":max_age=Nd" scales thresholds to N days.
    # GREEN = N/3 d, AMBER = 2N/3 d, RED = N d. For sparse event-driven tables
    # that update infrequently by design (e.g. roborev_threshold_changes).
    if [[ "$rest" =~ :max_age=([0-9]+)d ]]; then
        max_age_days="${BASH_REMATCH[1]}"
    fi

    # DB must exist
    if [[ ! -f "${DB}" ]]; then
        echo "CRITICAL:db-missing:DB not found at ${DB}"
        return
    fi

    # Check if table exists
    local tbl_exists
    tbl_exists=$(duck_run "${DB}" -init /dev/null -noheader -list \
        -c "SELECT count(*) FROM information_schema.tables WHERE table_name='${table}' AND table_schema='main'" \
        2>/dev/null | grep -oE '[0-9]+' | head -1 || echo "0")
    if [[ "${tbl_exists}" -eq 0 ]]; then
        echo "CRITICAL:table-missing:Table ${table} does not exist"
        return
    fi

    # Row count
    local row_count
    row_count=$(duck_run "${DB}" -init /dev/null -noheader -list \
        -c "SELECT COUNT(*) FROM ${table}" \
        2>/dev/null | grep -oE '[0-9]+' | head -1 || echo "0")
    if [[ "${row_count}" -eq 0 ]]; then
        echo "CRITICAL:empty:Table ${table} is empty (0 rows)"
        return
    fi

    # Age of most-recent row in seconds
    local max_ts age_sec
    max_ts=$(duck_run "${DB}" -init /dev/null -noheader -list \
        -c "SELECT epoch(MAX(${ts_col})) FROM ${table} WHERE ${ts_col} IS NOT NULL" \
        2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)?' | head -1 || echo "0")
    local now_sec
    now_sec=$(date +%s)
    if [[ -z "${max_ts}" || "${max_ts}" == "0" ]]; then
        echo "CRITICAL:no-timestamp:Table ${table} has no non-null ${ts_col}"
        return
    fi

    # DuckDB epoch() returns fractional seconds; strip decimals
    max_ts="${max_ts%%.*}"
    age_sec=$(( now_sec - max_ts ))
    if [[ "${age_sec}" -lt 0 ]]; then age_sec=0; fi

    # Human-readable age
    local age_human
    if [[ "${age_sec}" -lt 3600 ]]; then
        age_human="${age_sec}s"
    elif [[ "${age_sec}" -lt 86400 ]]; then
        age_human="$(( age_sec / 3600 ))h"
    else
        age_human="$(( age_sec / 86400 ))d"
    fi

    # Rate check (AMBER if < 5 rows/day on 7d average)
    local rate_detail=""
    if [[ -n "${do_rate_check}" ]]; then
        local rows_7d rate_per_day
        rows_7d=$(duck_run "${DB}" -init /dev/null -noheader -list \
            -c "SELECT COUNT(*) FROM ${table} WHERE ${ts_col} >= now() - INTERVAL 7 DAY" \
            2>/dev/null | grep -oE '[0-9]+' | head -1 || echo "0")
        # Integer arithmetic: 7 * rows_7d / 7 — we want rows/day * 10 to avoid floats
        local rate_x10=$(( rows_7d * 10 / 7 ))  # tenths of a row per day
        # < 5 rows/day = rate_x10 < 50
        if [[ "${rate_x10}" -lt 50 ]] && [[ "${age_sec}" -le "${THRESH_AMBER}" ]]; then
            # Fresh but sparse rate
            rate_detail="rate=$(( rate_x10 / 10 ))/day (7d); recent: ${age_human}"
            echo "AMBER:${age_human}:${rate_detail}"
            return
        fi
        rate_detail="rate=$(( rate_x10 / 10 ))/day (7d)"
    fi

    # Effective thresholds — scaled when per-table max_age is set
    local eff_green eff_amber eff_red
    if [[ -n "${max_age_days}" ]]; then
        eff_green=$(( max_age_days * 86400 / 3 ))
        eff_amber=$(( max_age_days * 86400 * 2 / 3 ))
        eff_red=$(( max_age_days * 86400 ))
    else
        eff_green="${THRESH_GREEN}"
        eff_amber="${THRESH_AMBER}"
        eff_red="${THRESH_RED}"
    fi

    # Classify by age
    if [[ "${age_sec}" -gt "${eff_red}" ]]; then
        echo "CRITICAL:${age_human}:${table} latest ${ts_col} is ${age_human} ago${rate_detail:+ (${rate_detail})}"
    elif [[ "${age_sec}" -gt "${eff_amber}" ]]; then
        echo "RED:${age_human}:${table} latest ${ts_col} is ${age_human} ago${rate_detail:+ (${rate_detail})}"
    elif [[ "${age_sec}" -gt "${eff_green}" ]]; then
        echo "AMBER:${age_human}:${table} latest ${ts_col} is ${age_human} ago${rate_detail:+ (${rate_detail})}"
    else
        echo "GREEN:${age_human}:${table} latest ${ts_col} is ${age_human} ago${rate_detail:+ (${rate_detail})}"
    fi
}

# ─── discover_untracked_stale: warn about tables NOT in TRACKED_TABLES ───────
# Emits INFO lines for tables whose MAX(ts) > 7d that we are not tracking.
# Does NOT affect exit code (fail-open: informational only).
discover_untracked_stale() {
    local db_path="$1"
    if [[ ! -f "${db_path}" ]]; then return 0; fi

    # Build a | -separated list of already-tracked table names for fast exclusion
    local tracked_set=""
    local spec
    for spec in "${TRACKED_TABLES[@]}"; do
        local tname="${spec%%:*}"
        tracked_set+="${tname}|"
    done
    tracked_set="${tracked_set%|}"  # strip trailing |

    # Get all user-table names from the DB
    local all_tables
    all_tables=$(duck_run "${db_path}" -init /dev/null -noheader -list \
        -c "SELECT table_name FROM information_schema.tables WHERE table_schema='main' ORDER BY 1" \
        2>/dev/null || true)

    if [[ -z "${all_tables}" ]]; then return 0; fi

    local tname
    while IFS= read -r tname; do
        [[ -z "${tname}" ]] && continue
        # Skip if already tracked
        if echo "${tracked_set}" | grep -qE "(^|\\|)${tname}(\\||$)"; then
            continue
        fi

        # Try common timestamp column names; use the first that exists
        local ts_candidate age_sec max_ts now_sec
        for ts_col in ts created_at logged_at started_at fired_at updated_at captured_at date; do
            local col_exists
            col_exists=$(duck_run "${db_path}" -init /dev/null -noheader -list \
                -c "SELECT count(*) FROM information_schema.columns
                    WHERE table_name='${tname}' AND column_name='${ts_col}'" \
                2>/dev/null | grep -oE '[0-9]+' | head -1 || echo "0")
            if [[ "${col_exists:-0}" -eq 1 ]]; then
                ts_candidate="${ts_col}"
                break
            fi
        done
        [[ -z "${ts_candidate:-}" ]] && continue

        # Get MAX; use CAST in case column is DATE not TIMESTAMP
        max_ts=$(duck_run "${db_path}" -init /dev/null -noheader -list \
            -c "SELECT epoch(CAST(MAX(${ts_candidate}) AS TIMESTAMP)) FROM ${tname} WHERE ${ts_candidate} IS NOT NULL" \
            2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)?' | head -1 || echo "0")
        [[ -z "${max_ts}" || "${max_ts}" == "0" ]] && continue

        max_ts="${max_ts%%.*}"
        now_sec=$(date +%s)
        age_sec=$(( now_sec - max_ts ))
        if [[ "${age_sec}" -gt "${THRESH_AMBER}" ]]; then
            local age_human="$(( age_sec / 86400 ))d"
            echo "  INFO: untracked table '${tname}' (${ts_candidate}): latest ${age_human} ago — consider adding to TRACKED_TABLES"
        fi
    done <<< "${all_tables}"
}

# ─── run_checks: populate arrays and return worst exit code ──────────────────
run_checks() {
    local db_path="${1:-${DB}}"
    DB="${db_path}"

    declare -a greens=() ambers=() reds=() criticals=()
    declare -a green_names=() amber_names=() red_names=() critical_names=()

    local spec result sev age_desc detail table_name
    for spec in "${TRACKED_TABLES[@]}"; do
        table_name="${spec%%:*}"
        result=$(check_table "${spec}")
        sev="${result%%:*}"
        rest="${result#*:}"
        age_desc="${rest%%:*}"
        detail="${rest#*:}"

        case "${sev}" in
            GREEN)    greens+=("${detail}")     green_names+=("${table_name}(${age_desc})") ;;
            AMBER)    ambers+=("${detail}")     amber_names+=("${table_name}(${age_desc})") ;;
            RED)      reds+=("${detail}")       red_names+=("${table_name}(${age_desc})") ;;
            CRITICAL) criticals+=("${detail}")  critical_names+=("${table_name}(${age_desc})") ;;
            *)        criticals+=("${result}")  critical_names+=("${table_name}(unknown)") ;;
        esac
    done

    # Determine worst exit code
    local exit_code=0
    [[ "${#ambers[@]}" -gt 0 ]] && exit_code=1
    [[ "${#reds[@]}" -gt 0 ]] && exit_code=2
    [[ "${#criticals[@]}" -gt 0 ]] && exit_code=2

    # ── Output ────────────────────────────────────────────────────────────────
    local n_crit="${#criticals[@]}"
    local n_red="${#reds[@]}"
    local n_amber="${#ambers[@]}"
    local n_green="${#greens[@]}"

    local summary_line
    summary_line="etl-freshness:"
    [[ "${n_crit}" -gt 0 ]]  && summary_line+=" ${n_crit} CRITICAL,"
    [[ "${n_red}" -gt 0 ]]   && summary_line+=" ${n_red} RED,"
    [[ "${n_amber}" -gt 0 ]] && summary_line+=" ${n_amber} AMBER,"
    [[ "${n_green}" -gt 0 ]] && summary_line+=" ${n_green} GREEN"
    summary_line="${summary_line%,}"

    if [[ "${MODE}" == "quiet" ]]; then
        if [[ "${exit_code}" -gt 0 ]]; then
            echo "${summary_line}"
        fi
        return "${exit_code}"
    fi

    echo "${summary_line}"

    if [[ "${MODE}" == "verbose" ]] || [[ "${exit_code}" -gt 0 ]]; then
        local i
        for (( i=0; i<n_crit; i++ )); do
            echo "  ${C_RED}CRITICAL: ${critical_names[$i]} — ${criticals[$i]}${C_RESET}"
        done
        for (( i=0; i<n_red; i++ )); do
            echo "  ${C_RED}RED: ${red_names[$i]} — ${reds[$i]}${C_RESET}"
        done
        for (( i=0; i<n_amber; i++ )); do
            echo "  ${C_AMBER}AMBER: ${amber_names[$i]} — ${ambers[$i]}${C_RESET}"
        done
        if [[ "${MODE}" == "verbose" ]]; then
            for (( i=0; i<n_green; i++ )); do
                echo "  ${C_GREEN}GREEN: ${green_names[$i]} — ${greens[$i]}${C_RESET}"
            done
        fi
    fi

    # ── Auto-discovery of untracked stale tables ──────────────────────────
    if [[ "${DISCOVER}" -eq 1 ]] && [[ "${MODE}" != "quiet" ]]; then
        discover_untracked_stale "${db_path}"
    fi

    return "${exit_code}"
}

# ─── SELFTEST ─────────────────────────────────────────────────────────────────
selftest() {
    local pass=0 fail=0
    local pid=$$

    _assert() {
        local label="$1" result="$2" expected="$3"
        if [[ "${result}" == "${expected}" ]]; then
            echo "PASS: ${label}"
            (( pass++ )) || true
        else
            echo "FAIL: ${label} (got='${result}', want='${expected}')"
            (( fail++ )) || true
        fi
    }

    # Test 1: missing DB → CRITICAL
    local absent_db="/tmp/etl_freshness_absent_${pid}.duckdb"
    rm -f "${absent_db}"
    ETL_FRESHNESS_DB="${absent_db}" DB="${absent_db}"
    local r1
    r1=$(ETL_FRESHNESS_DB="${absent_db}" check_table "hook_events:fired_at")
    _assert "missing-db-is-CRITICAL" "${r1%%:*}" "CRITICAL"

    # Build a fixture DB with fresh + stale data
    if ! command -v duckdb >/dev/null 2>&1; then
        if ! (command -v nix-shell >/dev/null 2>&1 && [[ -f "${NIX_DEFAULT}" ]]); then
            echo "SKIP: duckdb not reachable; skipping fixture-based tests"
            echo "─────────────────────────────"
            echo "Selftest: ${pass} PASS, ${fail} FAIL"
            (( fail == 0 ))
            return
        fi
    fi

    # Fresh fixture DB
    # Rate-checked tables (hook_events, agent_runs, roborev_review_lifecycle) need >35 rows
    # in 7 days to pass the 5-rows/day threshold check (5*7=35).
    local fresh_db="/tmp/etl_freshness_fresh_${pid}.duckdb"
    rm -f "${fresh_db}"
    duck_run "${fresh_db}" -c "
        CREATE TABLE hook_events (fired_at TIMESTAMP);
        INSERT INTO hook_events SELECT current_timestamp - INTERVAL (i * 2 || ' HOUR') AS fired_at
            FROM range(40) t(i);
        CREATE TABLE errors (logged_at TIMESTAMP);
        INSERT INTO errors VALUES (current_timestamp);
        CREATE TABLE agent_runs (started_at TIMESTAMP);
        INSERT INTO agent_runs SELECT current_timestamp - INTERVAL (i * 2 || ' HOUR') AS started_at
            FROM range(40) t(i);
        CREATE TABLE sessions (started_at TIMESTAMP);
        INSERT INTO sessions VALUES (current_timestamp);
        CREATE TABLE self_review_findings_stage1 (detected_at TIMESTAMP);
        INSERT INTO self_review_findings_stage1 VALUES (current_timestamp);
        CREATE TABLE roborev_review_lifecycle (created_at TIMESTAMP);
        INSERT INTO roborev_review_lifecycle
            SELECT current_timestamp - INTERVAL (i * 1 || ' HOUR') AS created_at
            FROM range(40) t(i);
        CREATE TABLE roborev_finding_lineage (created_at TIMESTAMP);
        INSERT INTO roborev_finding_lineage VALUES (current_timestamp);
        CREATE TABLE roborev_finding_lineage_summary (closed_at_last TIMESTAMP);
        INSERT INTO roborev_finding_lineage_summary VALUES (current_timestamp);
        CREATE TABLE roborev_daily_metrics (etl_run_at TIMESTAMP);
        INSERT INTO roborev_daily_metrics VALUES (current_timestamp);
        CREATE TABLE roborev_threshold_changes (changed_at_utc TIMESTAMP);
        INSERT INTO roborev_threshold_changes VALUES (current_timestamp);
    " >/dev/null 2>&1

    # Test 2: all tables fresh → all GREEN, exit 0
    ETL_FRESHNESS_DB="${fresh_db}" DB="${fresh_db}"
    local r2
    r2=$(MODE="quiet" ETL_FRESHNESS_DB="${fresh_db}" DB="${fresh_db}" run_checks "${fresh_db}") || true
    # quiet mode emits nothing when all green; if r2 is empty that's correct
    _assert "all-fresh-quiet-empty" "${r2}" ""

    # Test 3: stale fixture DB
    local stale_db="/tmp/etl_freshness_stale_${pid}.duckdb"
    rm -f "${stale_db}"
    duck_run "${stale_db}" -c "
        CREATE TABLE hook_events (fired_at TIMESTAMP);
        INSERT INTO hook_events VALUES (current_timestamp - INTERVAL 40 DAY);
        CREATE TABLE errors (logged_at TIMESTAMP);
        INSERT INTO errors VALUES (current_timestamp - INTERVAL 45 DAY);
        CREATE TABLE agent_runs (started_at TIMESTAMP);
        INSERT INTO agent_runs VALUES (current_timestamp - INTERVAL 1 HOUR);
        CREATE TABLE sessions (started_at TIMESTAMP);
        INSERT INTO sessions VALUES (current_timestamp);
        CREATE TABLE self_review_findings_stage1 (detected_at TIMESTAMP);
        INSERT INTO self_review_findings_stage1 VALUES (current_timestamp);
    " >/dev/null 2>&1

    local r3_hook
    r3_hook=$(ETL_FRESHNESS_DB="${stale_db}" DB="${stale_db}" check_table "hook_events:fired_at")
    _assert "stale-40d-hook_events-CRITICAL" "${r3_hook%%:*}" "CRITICAL"

    local r3_err
    r3_err=$(ETL_FRESHNESS_DB="${stale_db}" DB="${stale_db}" check_table "errors:logged_at")
    _assert "stale-45d-errors-CRITICAL" "${r3_err%%:*}" "CRITICAL"

    # Test 4: empty table → CRITICAL
    local empty_db="/tmp/etl_freshness_empty_${pid}.duckdb"
    rm -f "${empty_db}"
    duck_run "${empty_db}" -c "
        CREATE TABLE hook_events (fired_at TIMESTAMP);
    " >/dev/null 2>&1
    local r4
    r4=$(ETL_FRESHNESS_DB="${empty_db}" DB="${empty_db}" check_table "hook_events:fired_at")
    _assert "empty-table-CRITICAL" "${r4%%:*}" "CRITICAL"

    # Test 5: sparse rate check → AMBER (fresh but only 1 row in 7 days)
    local sparse_db="/tmp/etl_freshness_sparse_${pid}.duckdb"
    rm -f "${sparse_db}"
    duck_run "${sparse_db}" -c "
        CREATE TABLE agent_runs (started_at TIMESTAMP);
        INSERT INTO agent_runs VALUES (current_timestamp - INTERVAL 2 HOUR);
        INSERT INTO agent_runs VALUES (current_timestamp - INTERVAL 25 HOUR);
    " >/dev/null 2>&1
    local r5
    r5=$(ETL_FRESHNESS_DB="${sparse_db}" DB="${sparse_db}" check_table "agent_runs:started_at:rate")
    _assert "sparse-rate-AMBER" "${r5%%:*}" "AMBER"

    # Test 6: roborev_review_lifecycle fresh → GREEN
    local roborev_fresh_db="/tmp/etl_freshness_roborev_fresh_${pid}.duckdb"
    rm -f "${roborev_fresh_db}"
    duck_run "${roborev_fresh_db}" -c "
        CREATE TABLE roborev_review_lifecycle (created_at TIMESTAMP);
        INSERT INTO roborev_review_lifecycle
            SELECT current_timestamp - INTERVAL (i * 1 || ' HOUR') AS created_at
            FROM range(40) t(i);
    " >/dev/null 2>&1
    local r6
    r6=$(ETL_FRESHNESS_DB="${roborev_fresh_db}" DB="${roborev_fresh_db}" \
         check_table "roborev_review_lifecycle:created_at:rate")
    _assert "roborev_review_lifecycle-fresh-GREEN" "${r6%%:*}" "GREEN"

    # Test 7: roborev_review_lifecycle 5-days-old → AMBER
    local roborev_stale_db="/tmp/etl_freshness_roborev_stale_${pid}.duckdb"
    rm -f "${roborev_stale_db}"
    duck_run "${roborev_stale_db}" -c "
        CREATE TABLE roborev_review_lifecycle (created_at TIMESTAMP);
        INSERT INTO roborev_review_lifecycle VALUES (current_timestamp - INTERVAL 5 DAY);
    " >/dev/null 2>&1
    local r7
    r7=$(ETL_FRESHNESS_DB="${roborev_stale_db}" DB="${roborev_stale_db}" \
         check_table "roborev_review_lifecycle:created_at:rate")
    _assert "roborev_review_lifecycle-5d-AMBER" "${r7%%:*}" "AMBER"

    # Test 8: auto-discover finds an untracked table 8d stale → INFO line emitted
    local discover_db="/tmp/etl_freshness_discover_${pid}.duckdb"
    rm -f "${discover_db}"
    duck_run "${discover_db}" -c "
        CREATE TABLE untracked_widget (created_at TIMESTAMP);
        INSERT INTO untracked_widget VALUES (current_timestamp - INTERVAL 8 DAY);
    " >/dev/null 2>&1
    local r8
    r8=$(ETL_FRESHNESS_DB="${discover_db}" DB="${discover_db}" DISCOVER=1 \
         discover_untracked_stale "${discover_db}")
    local r8_found
    r8_found=$(echo "${r8}" | grep -c "untracked_widget" || true)
    _assert "discover-untracked-8d-INFO" "${r8_found}" "1"

    # Test 9a: max_age=60d — 18-day-old sparse table → GREEN (not RED)
    local maxage_db="/tmp/etl_freshness_maxage_${pid}.duckdb"
    rm -f "${maxage_db}"
    duck_run "${maxage_db}" -c "
        CREATE TABLE roborev_threshold_changes (changed_at_utc TIMESTAMP);
        INSERT INTO roborev_threshold_changes VALUES (current_timestamp - INTERVAL 18 DAY);
    " >/dev/null 2>&1
    local r9a
    r9a=$(ETL_FRESHNESS_DB="${maxage_db}" DB="${maxage_db}" \
          check_table "roborev_threshold_changes:changed_at_utc:max_age=60d")
    _assert "max_age-60d-18d-GREEN" "${r9a%%:*}" "GREEN"

    # Test 9b: max_age=60d — 50-day-old sparse table → RED
    local maxage_stale_db="/tmp/etl_freshness_maxage_stale_${pid}.duckdb"
    rm -f "${maxage_stale_db}"
    duck_run "${maxage_stale_db}" -c "
        CREATE TABLE roborev_threshold_changes (changed_at_utc TIMESTAMP);
        INSERT INTO roborev_threshold_changes VALUES (current_timestamp - INTERVAL 50 DAY);
    " >/dev/null 2>&1
    local r9b
    r9b=$(ETL_FRESHNESS_DB="${maxage_stale_db}" DB="${maxage_stale_db}" \
          check_table "roborev_threshold_changes:changed_at_utc:max_age=60d")
    _assert "max_age-60d-50d-RED" "${r9b%%:*}" "RED"

    # Test 10: --list-tables prints tracked table count
    local r10
    r10=$(MODE="list-tables" bash "${BASH_SOURCE[0]}" --list-tables 2>/dev/null | head -1)
    _assert "list-tables-header" "${r10%% *}" "Tracked"

    # Cleanup
    rm -f "${fresh_db}" "${stale_db}" "${empty_db}" "${sparse_db}" "${absent_db}" \
          "${roborev_fresh_db}" "${roborev_stale_db}" "${discover_db}" \
          "${maxage_db}" "${maxage_stale_db}" 2>/dev/null || true

    echo "─────────────────────────────"
    echo "Selftest: ${pass} PASS, ${fail} FAIL"
    (( fail == 0 ))
}

# ─── Dispatch ────────────────────────────────────────────────────────────────
if [[ "${MODE}" == "selftest" ]]; then
    selftest
    exit $?
fi

if [[ "${MODE}" == "list-tables" ]]; then
    echo "Tracked tables (${#TRACKED_TABLES[@]}):"
    for _lt_spec in "${TRACKED_TABLES[@]}"; do
        _lt_tname="${_lt_spec%%:*}"
        _lt_rest="${_lt_spec#*:}"
        _lt_ts_col="${_lt_rest%%:*}"
        _lt_rate_flag=""
        [[ "${_lt_rest}" == *":rate" ]] && _lt_rate_flag=" [rate-check]"
        echo "  ${_lt_tname}:${_lt_ts_col}${_lt_rate_flag}"
    done
    exit 0
fi

# ─── Guard: DB must exist ────────────────────────────────────────────────────
if [[ ! -f "${DB}" ]]; then
    if [[ "${MODE}" != "quiet" ]]; then
        echo "etl-freshness: CRITICAL — DB not found at ${DB}"
    fi
    exit 2
fi

run_checks "${DB}"
