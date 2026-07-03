#!/usr/bin/env bash
# self_review_stage1.sh — Stage 1 SQL detector for overnight self-review job.
#
# Reads:  ~/.claude/logs/unified.duckdb
# Writes: unified.duckdb table self_review_findings_stage1 (CREATE IF NOT EXISTS)
#
# Usage:
#   self_review_stage1.sh [--dry-run]   # --dry-run is the default
#   self_review_stage1.sh --write       # actually upsert findings into DB
#   SELFTEST=1 bash self_review_stage1.sh
#
# Stage 2 (LLM proposer) is DEFERRED. This script is Stage 1 only.
# Do NOT install the launchd plist from this script.

set -euo pipefail

# ─── PATH (launchd runs us with a bare PATH) ─────────────────────────────────
# /nix/var/nix/profiles/default/bin is the stable nix-shell location under the
# multi-user nix install; launchd's default PATH omits it. Homebrew/usr dirs are
# kept as a fallback for the duck_run() degradation path below.
export PATH="/nix/var/nix/profiles/default/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

# ─── Recursion / fork-bomb guard ─────────────────────────────────────────────
# Depth incremented before any work so nested invocations see depth > 0.
: "${SELF_REVIEW_DEPTH:=0}"
if (( SELF_REVIEW_DEPTH > 0 )); then
    echo "[self_review_stage1] ERROR: recursion detected (depth=$SELF_REVIEW_DEPTH). Abort." >&2
    exit 1
fi
export SELF_REVIEW_DEPTH=$(( SELF_REVIEW_DEPTH + 1 ))

# ─── Paths ───────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NIX_DEFAULT="$(cd "${SCRIPT_DIR}/../.." 2>/dev/null && pwd)/default.nix"
# NIX_TARGET is overridden to the GC-rooted .drv after log() is defined below.
# Using the drv avoids re-fetching nixpkgs from github.com at 02:30 (llm#704).
NIX_TARGET="${NIX_DEFAULT}"
REFRESH="${HOME}/.claude/scripts/nix_gcroot_refresh.sh"
DB="${HOME}/.claude/logs/unified.duckdb"
SQL_FILE="${SCRIPT_DIR}/self_review_stage1.sql"
LOG_DIR="${HOME}/.claude/logs"
LOG_FILE="${LOG_DIR}/self_review_stage1.log"
LOCK_FILE="/tmp/self_review_stage1.lock"

# ─── Logging ─────────────────────────────────────────────────────────────────
log() {
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "${ts} $*" | tee -a "${LOG_FILE}"
}

# ─── GC-root resolution (offline-safe, llm#704) ─────────────────────────────
# Best-effort: seed/refresh a GC-rooted derivation when online so that the
# 02:30 cron run does not trigger a nixpkgs tarball re-fetch from github.com.
# nix_gcroot_refresh.sh returns exit 0 + the drv path even when offline if a
# root was previously seeded (llm#596, llm#673). Falls back to NIX_DEFAULT
# (may need network) when the refresh helper is absent or the root is missing.
if [ -x "${REFRESH}" ]; then
    _drv="$("${REFRESH}" "${NIX_DEFAULT}" 2>/dev/null | tail -1 || true)"
    if [ -n "${_drv:-}" ] && [ -e "${_drv}" ]; then
        NIX_TARGET="${_drv}"
        log "INFO: nix target = GC-rooted drv (offline-safe)"
    else
        log "WARN: GC root unavailable; falling back to default.nix (may need network)"
    fi
else
    log "INFO: nix_gcroot_refresh not found; using default.nix"
fi

# ─── duckdb invocation ───────────────────────────────────────────────────────
# duck_run: run duckdb from the project nix shell so the DuckDB version matches
# the rest of the pipeline (unified.duckdb is written by nix-shell duckdb 1.4.x
# elsewhere). Falls back to PATH duckdb if nix-shell or default.nix is absent.
# stdin is passed through (used for the piped-SQL dry-run path). printf %q
# re-quotes each arg so the inner `bash -c` reconstructs them exactly (handles
# the `-c "SELECT … (*)…"` case with spaces and parens).
duck_run() {
    if command -v nix-shell >/dev/null 2>&1 && [[ -f "${NIX_DEFAULT}" ]]; then
        local q="" a
        for a in "$@"; do q+=" $(printf '%q' "$a")"; done
        nix-shell "${NIX_TARGET}" --run "duckdb${q}"
    else
        duckdb "$@"
    fi
}

# ─── Core functions (called directly; no bash "$0" re-invocation) ─────────────

# run_dry: execute SQL inside a transaction that is rolled back at the end.
# Writes nothing to DB. Returns duckdb exit code.
run_dry() {
    local db_path="${1:-${DB}}"
    if [[ ! -f "${db_path}" ]]; then
        log "INFO: DB not found at ${db_path}. Nothing to analyse. Exiting 0."
        return 0
    fi
    if [[ ! -f "${SQL_FILE}" ]]; then
        log "ERROR: SQL file not found at ${SQL_FILE}." >&2
        return 1
    fi
    log "INFO: --dry-run mode. DB = ${db_path}"
    {
        printf 'BEGIN TRANSACTION;\n'
        cat "${SQL_FILE}"
        printf '\nROLLBACK;\n'
    } | duck_run "${db_path}" 2>&1 | tee -a "${LOG_FILE}"
}

# run_write: execute SQL and persist findings to DB.
run_write() {
    local db_path="${1:-${DB}}"
    if [[ ! -f "${db_path}" ]]; then
        log "INFO: DB not found at ${db_path}. Nothing to analyse. Exiting 0."
        return 0
    fi
    if [[ ! -f "${SQL_FILE}" ]]; then
        log "ERROR: SQL file not found at ${SQL_FILE}." >&2
        return 1
    fi
    log "INFO: --write mode. DB = ${db_path}"
    duck_run "${db_path}" < "${SQL_FILE}" 2>&1 | tee -a "${LOG_FILE}"
    local status="${PIPESTATUS[0]}"
    if (( status == 0 )); then
        local count
        count="$(duck_run "${db_path}" -init /dev/null -noheader -list -c \
            "SELECT COUNT(*) FROM self_review_findings_stage1" \
            2>/dev/null | grep -oE '[0-9]+' | tail -n1 || echo 'unknown')"
        log "INFO: Total cumulative findings in table: ${count}"
    else
        log "ERROR: SQL execution failed (exit ${status})." >&2
        return "${status}"
    fi
}

# ─── SELFTEST mode: calls functions directly; NO bash "$0" re-invocation ──────
selftest() {
    local pass=0 fail=0

    _assert() {
        local label="$1" result="$2" expected="$3"
        if [[ "$result" == "$expected" ]]; then
            echo "PASS: $label"
            (( pass++ )) || true
        else
            echo "FAIL: $label (got='$result', want='$expected')"
            (( fail++ )) || true
        fi
    }

    # Test 1: absent DB → run_dry returns 0
    local fake_db="/tmp/self_review_absent_$$.duckdb"
    rm -f "${fake_db}"
    run_dry "${fake_db}" >/dev/null 2>&1
    _assert "absent-db-exits-0" "$?" "0"

    # Test 2: SQL file exists
    local sql_exists=1
    [[ -f "${SQL_FILE}" ]] && sql_exists=0
    _assert "sql-file-exists" "${sql_exists}" "0"

    # Test 3: duckdb reachable (via nix shell, or PATH fallback).
    # Uses NIX_TARGET (GC-rooted drv when available) to avoid network at test time.
    local db_avail=1
    if command -v nix-shell >/dev/null 2>&1 && [[ -f "${NIX_DEFAULT}" ]]; then
        nix-shell "${NIX_TARGET}" --run "command -v duckdb" >/dev/null 2>&1 && db_avail=0
    else
        command -v duckdb >/dev/null 2>&1 && db_avail=0
    fi
    _assert "duckdb-reachable" "${db_avail}" "0"

    # Test 4: lock file not present initially (clean state after removing it)
    rm -f "${LOCK_FILE}"
    local no_lock=1
    [[ ! -f "${LOCK_FILE}" ]] && no_lock=0
    _assert "no-stale-lock" "${no_lock}" "0"

    # Test 5: depth guard — SELF_REVIEW_DEPTH already == 1 (set at top of script)
    # The guard fires when depth > 0 at script entry. We simulate a nested call
    # by checking the guard condition directly (no re-invocation of the script).
    local depth_guard_check=1
    if (( SELF_REVIEW_DEPTH > 0 )); then
        depth_guard_check=0   # guard WOULD fire (correct)
    fi
    _assert "depth-guard-condition-true" "${depth_guard_check}" "0"

    # Test 6: run_dry against real DB exits 0
    local dry_status=0
    run_dry "${DB}" >/dev/null 2>&1 || dry_status=$?
    _assert "dry-run-real-db-exits-0" "${dry_status}" "0"

    echo "─────────────────────────────"
    echo "Selftest: ${pass} PASS, ${fail} FAIL"
    (( fail == 0 ))
}

# ─── Dispatch ────────────────────────────────────────────────────────────────
if [[ "${SELFTEST:-0}" == "1" ]]; then
    selftest
    exit $?
fi

# ─── Parse args ──────────────────────────────────────────────────────────────
DRY_RUN=1   # default: dry-run

for arg in "$@"; do
    case "${arg}" in
        --dry-run)  DRY_RUN=1  ;;
        --write)    DRY_RUN=0  ;;
        *)
            echo "Usage: $0 [--dry-run|--write]" >&2
            exit 1
            ;;
    esac
done

# ─── Defensive: exit 0 if DB absent ─────────────────────────────────────────
if [[ ! -f "${DB}" ]]; then
    log "INFO: DB not found at ${DB}. Nothing to analyse. Exiting 0."
    exit 0
fi

# ─── Defensive: exit 0 if SQL file absent ───────────────────────────────────
if [[ ! -f "${SQL_FILE}" ]]; then
    log "ERROR: SQL file not found at ${SQL_FILE}. Cannot continue." >&2
    exit 1
fi

# ─── Lock file to prevent concurrent runs ────────────────────────────────────
if [[ -f "${LOCK_FILE}" ]]; then
    local_pid="$(cat "${LOCK_FILE}" 2>/dev/null || echo '')"
    if kill -0 "${local_pid}" 2>/dev/null; then
        log "INFO: Another instance (pid=${local_pid}) is running. Exiting."
        exit 0
    else
        log "INFO: Removing stale lock (pid=${local_pid} is gone)."
        rm -f "${LOCK_FILE}"
    fi
fi
echo $$ > "${LOCK_FILE}"
trap 'rm -f "${LOCK_FILE}"' EXIT

# ─── Execute ──────────────────────────────────────────────────────────────────
if (( DRY_RUN == 1 )); then
    run_dry "${DB}"
    log "INFO: --dry-run complete."
else
    run_write "${DB}"
    log "INFO: Done."
fi

# Stamp for cron_catchup.sh catch-up detection
mkdir -p "${HOME}/.claude/logs/stamps"
date -u +%Y-%m-%dT%H:%M:%SZ > "${HOME}/.claude/logs/stamps/self-review-stage1.stamp"
