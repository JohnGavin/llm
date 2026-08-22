#!/usr/bin/env bash
# private_data_history_audit.sh — scheduled full-history PII audit (Layer 5).
#
# Wraps `private_data_scan.sh --full-history` in the housekeeping-framework
# pattern used by worktree_gc.sh / secret_exposure_scan.sh: --dry-run
# default-safe entry, a housekeeping_runs heartbeat row, and a log line per
# run, so a scanner that silently stopped firing at its scheduled slot is
# distinguishable from a scanner that genuinely found nothing
# (zero-metric-evidence-or-defect, housekeeping-framework rule).
#
# This is the deepest, slowest layer: pre-commit/pre-push/CI only ever see
# NEW content going forward from the point they were installed. This audit
# is what catches PII that entered history BEFORE any of those layers
# existed -- exactly the shape of the 2026-08-22 incident (present for 4
# months before any control could have seen it).
#
# Runs WITH the deny-list (--require-denylist, the private_data_scan.sh
# default) because this always runs locally, with access to
# ~/.config/private_values.env -- unlike CI, which deliberately runs
# --no-denylist (see private-data-scanning.md).
#
# This script never auto-remediates. There is no safe machine fix for PII
# already in published history -- remediation is always a human decision
# among the options already documented in repo-visibility-gate.md's "The
# audit itself" section (orphan-squash / git filter-repo / accept and
# publish-private instead). This script's job ends at REPORTING.
#
# Usage:
#   private_data_history_audit.sh              # dry-run: scan + report only
#   private_data_history_audit.sh --apply       # same scan; --apply exists
#                                                # only to match the
#                                                # housekeeping-framework
#                                                # convention (dry-run vs
#                                                # apply) -- there is no
#                                                # destructive action this
#                                                # flag unlocks; both modes
#                                                # scan and report, never
#                                                # mutate history.
#   private_data_history_audit.sh --selftest
#
# Log: ~/.claude/logs/private_data_history_audit.log
# Housekeeping: housekeeping_runs (task='private_data_history_audit')
# Delivered launchd plist (NOT installed by this dispatch):
#   .claude/launchd/com.claude.private-data-history-audit.plist
#
# Origin: 2026-08-22 PII incident.

set -uo pipefail

export PATH="/nix/var/nix/profiles/default/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

HOME_DIR="${HOME:-/Users/johngavin}"
LOG_DIR="${HOME_DIR}/.claude/logs"
LOG_FILE="${LOG_DIR}/private_data_history_audit.log"
UNIFIED_DB="${UNIFIED_DB_PATH:-${HOME_DIR}/.claude/logs/unified.duckdb}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCANNER="${SCANNER:-${SCRIPT_DIR}/private_data_scan.sh}"

APPLY=0
SELFTEST=0
for arg in "$@"; do
    case "$arg" in
        --apply) APPLY=1 ;;
        --selftest) SELFTEST=1 ;;
        -h|--help) echo "Usage: private_data_history_audit.sh [--apply] [--selftest]"; exit 0 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

log_line() {
    { mkdir -p "$LOG_DIR" 2>/dev/null
      printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" "$1" >> "$LOG_FILE"
    } 2>/dev/null || true
}

_duckdb_ok=0
command -v duckdb >/dev/null 2>&1 && [ -f "$UNIFIED_DB" ] && _duckdb_ok=1
_run_id=""

hk_run_start() {
    [ "$_duckdb_ok" = "1" ] || return 0
    _run_id="$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    [ -n "$_run_id" ] || return 0
    duckdb -init /dev/null "$UNIFIED_DB" -c "
        INSERT OR IGNORE INTO housekeeping_runs
          (id, task, source_script, started_at, status, rows_written)
        VALUES ('${_run_id}', 'private_data_history_audit', '${SCRIPT_DIR}/private_data_history_audit.sh',
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

if [ "$SELFTEST" -eq 1 ]; then
    # Exercises this wrapper's own logic (arg parsing, housekeeping calls,
    # scanner-not-found fail-closed path) against a fake scanner -- NOT a
    # re-test of private_data_scan.sh's detectors themselves (that is
    # private_data_scan.sh --selftest's job; this wrapper's contract with
    # it is "call it, propagate its exit code, log the outcome").
    pass=0; total=0
    _check() { total=$((total + 1)); if [ "$1" = "0" ]; then pass=$((pass + 1)); echo "PASS  $2"; else echo "FAIL  $2"; fi; }

    fake_dir="$(mktemp -d "${TMPDIR:-/tmp}/pds_audit_selftest.XXXXXX")"
    cat > "$fake_dir/private_data_scan.sh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *--full-history*) echo "private-data-scan: clean -- 0 findings"; exit 0 ;;
esac
exit 0
EOF
    chmod +x "$fake_dir/private_data_scan.sh"
    set +e
    SCANNER="$fake_dir/private_data_scan.sh" bash "$0" > /tmp/pds_audit_out.$$ 2>&1
    rc=$?
    set -e
    if [ "$rc" -eq 0 ] && grep -q "clean" /tmp/pds_audit_out.$$; then
        _check 0 "wrapper calls the scanner in --full-history mode and propagates a clean exit"
    else
        _check 1 "wrapper did not propagate a clean exit correctly (rc=$rc)"
    fi
    rm -f /tmp/pds_audit_out.$$

    cat > "$fake_dir/private_data_scan.sh" <<'EOF'
#!/usr/bin/env bash
echo "private-data-scan: 2 finding(s)"
exit 1
EOF
    chmod +x "$fake_dir/private_data_scan.sh"
    set +e
    SCANNER="$fake_dir/private_data_scan.sh" bash "$0" > /tmp/pds_audit_out2.$$ 2>&1
    rc=$?
    set -e
    if [ "$rc" -eq 1 ] && grep -q "finding" /tmp/pds_audit_out2.$$; then
        _check 0 "wrapper propagates a non-zero (findings-present) exit from the scanner"
    else
        _check 1 "wrapper did not propagate the scanner's findings exit code (rc=$rc)"
    fi
    rm -f /tmp/pds_audit_out2.$$

    set +e
    SCANNER="$fake_dir/does_not_exist.sh" bash "$0" > /tmp/pds_audit_out3.$$ 2>&1
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        _check 0 "wrapper fails closed (non-zero exit) when the scanner binary is missing"
    else
        _check 1 "wrapper should fail closed when the scanner binary is missing"
    fi
    rm -f /tmp/pds_audit_out3.$$

    rm -rf "$fake_dir"
    echo ""
    echo "private_data_history_audit selftest: $pass/$total PASS"
    [ "$pass" -eq "$total" ] && exit 0
    exit 1
fi

if [ ! -x "$SCANNER" ]; then
    echo "BLOCKED (fail-closed): scanner not found or not executable at $SCANNER" >&2
    log_line "BLOCKED_SCANNER_MISSING"
    exit 1
fi

hk_run_start
echo "private_data_history_audit: starting full-history scan (mode=$([ "$APPLY" -eq 1 ] && echo apply || echo dry-run); both modes scan+report only, see header)"

OUT="$("$SCANNER" --full-history 2>&1)"
RC=$?
printf '%s\n' "$OUT"

FINDINGS_COUNT="$(printf '%s\n' "$OUT" | "${GREP:-grep}" -oE '^private-data-scan: [0-9]+ finding' | "${GREP:-grep}" -oE '[0-9]+' | head -1)"
FINDINGS_COUNT="${FINDINGS_COUNT:-0}"

if [ "$RC" -ne 0 ]; then
    echo "" >&2
    echo "private_data_history_audit: scan reported findings or an internal error (rc=$RC)." >&2
    echo "This does NOT auto-remediate -- see .claude/rules/repo-visibility-gate.md's" >&2
    echo "'The audit itself' section for remediation options (orphan-squash / git" >&2
    echo "filter-repo / accept and keep private). Review the findings above." >&2
    log_line "mode=$([ "$APPLY" -eq 1 ] && echo apply || echo dry-run) findings=${FINDINGS_COUNT} status=findings_or_error rc=${RC}"
    hk_run_end "ok" "$FINDINGS_COUNT"
    exit "$RC"
fi

log_line "mode=$([ "$APPLY" -eq 1 ] && echo apply || echo dry-run) findings=0 status=clean"
hk_run_end "ok" "0"
exit 0
