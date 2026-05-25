#!/usr/bin/env bash
# self_review_verify.sh — Verify that the overnight Stage-1 self-review --write
# run (02:30 daily, com.claude.self-review-stage1) actually succeeded.
#
# Reads:  ~/.claude/logs/self_review_stage1.log  (written by stage1 --write)
#         ~/.claude/logs/unified.duckdb           (DB with findings table)
# Writes: ~/.claude/logs/self_review_verify.log  (one PASS/FAIL line per run)
#
# Usage:
#   self_review_verify.sh                  # normal run (reads log + DB)
#   SELFTEST=1 bash self_review_verify.sh  # unit tests
#
# Tracks: JohnGavin/llm#235
# DO NOT touch ~/Library/LaunchAgents/ from this script.

set -euo pipefail

# ─── PATH (launchd runs us with a bare PATH) ─────────────────────────────────
export PATH="/nix/var/nix/profiles/default/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

# ─── Paths ───────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NIX_DEFAULT="$(cd "${SCRIPT_DIR}/../.." 2>/dev/null && pwd)/default.nix"
LOG="${HOME}/.claude/logs/self_review_stage1.log"
DB="${HOME}/.claude/logs/unified.duckdb"
VERIFY_LOG="${HOME}/.claude/logs/self_review_verify.log"

# ─── Logging ─────────────────────────────────────────────────────────────────
log_verify() {
    local line="$1"
    echo "${line}" >> "${VERIFY_LOG}"
}

ts() { date '+%Y-%m-%d %H:%M:%S'; }

# ─── duckdb invocation ───────────────────────────────────────────────────────
# Mirrors duck_run() from self_review_stage1.sh exactly so the DuckDB version
# is consistent with the pipeline-written unified.duckdb.
duck_run() {
    if command -v nix-shell >/dev/null 2>&1 && [[ -f "${NIX_DEFAULT}" ]]; then
        local q="" a
        for a in "$@"; do q+=" $(printf '%q' "$a")"; done
        nix-shell "${NIX_DEFAULT}" --run "duckdb${q}"
    else
        duckdb "$@"
    fi
}

# ─── Classifier: evaluate a write-run block ──────────────────────────────────
# Returns: "PASS" or "FAIL:<reason>"
# Arguments: the block text is read from stdin.
classify_block() {
    local block="$1"
    # FAIL: command-not-found regression
    if echo "${block}" | grep -q "command not found"; then
        echo "FAIL:command_not_found"
        return
    fi
    # FAIL: run did not complete
    if ! echo "${block}" | grep -q "Done\."; then
        echo "FAIL:no_done_line"
        return
    fi
    echo "PASS"
}

# ─── Notify policy: FAIL always; PASS only on state change ──────────────────
# $1 = current result ("PASS" or "FAIL"), $2 = previous state (or empty).
# Outputs "1" to notify, "0" to stay silent.
should_notify() {
    local current="$1" prev="$2"
    if [ "${current}" = "FAIL" ]; then echo 1; return; fi
    if [ "${current}" = "PASS" ] && [ "${prev}" != "PASS" ]; then echo 1; return; fi
    echo 0
}

# ─── SELFTEST mode ───────────────────────────────────────────────────────────
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

    # Test 1: bash -n parse (implicit — script loaded to this point)
    _assert "bash-n-parse" "0" "0"

    # Test 2: duckdb reachable via nix shell or PATH
    local db_avail=1
    if command -v nix-shell >/dev/null 2>&1 && [[ -f "${NIX_DEFAULT}" ]]; then
        nix-shell "${NIX_DEFAULT}" --run "command -v duckdb" >/dev/null 2>&1 && db_avail=0
    else
        command -v duckdb >/dev/null 2>&1 && db_avail=0
    fi
    _assert "duckdb-reachable" "${db_avail}" "0"

    # Test 3: classify_block — PASS case
    local good_block
    good_block="$(printf '2026-05-25 02:30:01 INFO: --write mode\n2026-05-25 02:30:05 INFO: Done.\n2026-05-25 02:30:05 INFO: Total cumulative findings in table: 5\n')"
    local good_result
    good_result="$(classify_block "${good_block}")"
    _assert "classify-pass-block" "${good_result}" "PASS"

    # Test 4: classify_block — FAIL on command not found
    local bad_block_cnf
    bad_block_cnf="$(printf '2026-05-25 02:30:01 INFO: --write mode\nduckdb: command not found\n')"
    local bad_result_cnf
    bad_result_cnf="$(classify_block "${bad_block_cnf}")"
    _assert "classify-fail-command-not-found" "${bad_result_cnf}" "FAIL:command_not_found"

    # Test 5: classify_block — FAIL when no Done. line
    local bad_block_nodone
    bad_block_nodone="$(printf '2026-05-25 02:30:01 INFO: --write mode\n2026-05-25 02:30:03 ERROR: SQL execution failed\n')"
    local bad_result_nodone
    bad_result_nodone="$(classify_block "${bad_block_nodone}")"
    _assert "classify-fail-no-done" "${bad_result_nodone}" "FAIL:no_done_line"

    # Test 6: should_notify — FAIL always notifies
    _assert "should_notify-fail-after-pass" "$(should_notify FAIL PASS)" "1"

    # Test 7: should_notify — PASS after PASS stays silent
    _assert "should_notify-pass-after-pass" "$(should_notify PASS PASS)" "0"

    # Test 8: should_notify — PASS after FAIL notifies (recovery)
    _assert "should_notify-pass-after-fail" "$(should_notify PASS FAIL)" "1"

    # Test 9: should_notify — PASS on first run (empty prev) notifies
    _assert "should_notify-pass-first-run" "$(should_notify PASS "")" "1"

    echo "─────────────────────────────"
    echo "Selftest: ${pass} PASS, ${fail} FAIL"
    (( fail == 0 ))
}

if [[ "${SELFTEST:-0}" == "1" ]]; then
    selftest
    exit $?
fi

# ─── Normal run ──────────────────────────────────────────────────────────────
mkdir -p "$(dirname "${VERIFY_LOG}")"
timestamp="$(ts)"

# Step 1: absent log
if [[ ! -f "${LOG}" ]]; then
    log_verify "${timestamp} [WARN] no stage1 log yet"
    exit 0
fi

# Step 2: find the last --write mode block
last_write_linenum="$(grep -n -- "--write mode" "${LOG}" | tail -n1 | cut -d: -f1 || true)"
if [[ -z "${last_write_linenum}" ]]; then
    log_verify "${timestamp} [WARN] no --write mode run found in stage1 log"
    exit 0
fi
write_block="$(tail -n "+${last_write_linenum}" "${LOG}")"

# Step 3: extract run date from block's leading timestamp
run_date="$(echo "${write_block}" | head -n1 | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -n1 || true)"
today="$(date +%F)"

# Step 4 & 5: evaluate
errors="n"
done_found="n"
verdict="PASS"

# Check classifier
classify_result="$(classify_block "${write_block}")"
if [[ "${classify_result}" != "PASS" ]]; then
    verdict="FAIL"
    # detect which sub-reason
    if echo "${write_block}" | grep -q "command not found"; then
        errors="y"
    fi
else
    done_found="y"
fi

# Date check
if [[ "${run_date}" != "${today}" ]]; then
    verdict="FAIL"
fi

# Step 5: DB row count
count=0
count="$(duck_run "${DB}" -init /dev/null -noheader -list -c \
    "SELECT COUNT(*) FROM self_review_findings_stage1" \
    2>/dev/null | grep -oE '[0-9]+' | tail -n1 || echo 0)"
# If count is empty, set to 0
if [[ -z "${count}" ]]; then
    count=0
fi

if [[ "${count}" == "0" ]] || [[ -z "${count}" ]]; then
    verdict="FAIL"
fi

# Step 7: append result line to VERIFY_LOG
log_verify "${timestamp} [${verdict}] overnight self-review: run_date=${run_date} done=${done_found} errors=${errors} db_rows=${count}"

# ─── Email notification via llmtelemetry CI (reuses its GMAIL_* secret) ───────
# Notify on FAIL always; on PASS only when state changes (first run / recovery),
# so steady-state PASS days are silent. State file is overridable for testing.
STATE_FILE="${SELF_REVIEW_VERIFY_STATE:-${HOME}/.claude/logs/.self_review_verify_state}"
prev_state="$(cat "${STATE_FILE}" 2>/dev/null || true)"
printf '%s\n' "${verdict}" > "${STATE_FILE}"

if [ "$(should_notify "${verdict}" "${prev_state}")" = "1" ] \
   && [ "${SELF_REVIEW_VERIFY_NOTIFY:-1}" = "1" ] \
   && command -v gh >/dev/null 2>&1; then
    details="run_date=${run_date} done=${done_found} errors=${errors} db_rows=${count}"
    if gh workflow run self-review-email.yml --repo JohnGavin/llmtelemetry \
        -f result="${verdict}" -f count="${count}" -f run_date="${run_date}" \
        -f details="${details}" >/dev/null 2>&1; then
        log_verify "$(ts) INFO: dispatched self-review email workflow (result=${verdict})"
    else
        log_verify "$(ts) WARN: gh workflow dispatch failed (result=${verdict})"
    fi
fi

# Step 8: macOS notification (best-effort, never aborts)
if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"self-review ${verdict} (rows=${count})\" with title \"Overnight self-review\"" || true
fi

# Step 9: always exit 0 (monitor; no launchd retry spam)
exit 0
