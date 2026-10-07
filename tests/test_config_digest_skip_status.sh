#!/usr/bin/env bash
# tests/test_config_digest_skip_status.sh
#
# llm#1340: the combined config+KB digest skips empty days. This runs a copy of
# the REAL bin/config_digest_cron.sh inside a fake repo + fake HOME, with a stub
# in place of nix-shell (via the NIX_SHELL_CMD seam) whose exit status stands in
# for send_config_digest_email.R's, and proves the wrapper maps it to:
#
#   email script exit 0   -> housekeeping_runs.status 'ok'      wrapper exit 0
#   email script exit 10  -> housekeeping_runs.status 'skipped' wrapper exit 0
#                            (and the cron_catchup stamp IS written, so a skip
#                            is not mistaken for a missed run)
#   email script exit 1   -> housekeeping_runs.status 'failed'  wrapper exit 1
#
# Exit codes: 0 all pass, 1 a check failed, 3 INDETERMINATE (duckdb/python3
# missing, so the ledger cannot be inspected -- reported, never a silent pass).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DUCKDB_BIN="$(command -v duckdb || true)"
PY_BIN="$(command -v python3 || true)"
if [ -z "${DUCKDB_BIN}" ] || [ -z "${PY_BIN}" ]; then
  echo "INDETERMINATE: duckdb='${DUCKDB_BIN}' python3='${PY_BIN}' -- cannot inspect housekeeping_runs"
  exit 3
fi

PASS=0
FAIL=0
TMPDIR_ROOT="$(mktemp -d /tmp/test_config_digest_skip_XXXXXX)"
trap 'rm -rf "${TMPDIR_ROOT}"' EXIT

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 -- ${2:-}"; FAIL=$((FAIL + 1)); }

# run_case TAG STUB_EXIT -> sets H (fake HOME), RC (wrapper exit), DB
run_case() {
  local tag="$1" stub_exit="$2"
  H="${TMPDIR_ROOT}/${tag}"
  DB="${H}/unified.duckdb"
  mkdir -p "${H}/.claude/logs" "${H}/bin" "${H}/repo/bin" "${H}/repo/.claude/scripts/lib"
  cp "${REPO_ROOT}/bin/config_digest_cron.sh" "${H}/repo/bin/config_digest_cron.sh"
  cp "${REPO_ROOT}/.claude/scripts/lib/load_email_creds.sh" "${H}/repo/.claude/scripts/lib/load_email_creds.sh"
  printf 'cron_deploy_pull() { return 0; }\n' > "${H}/repo/.claude/scripts/cron_deploy_pull.sh"
  printf 'wait_for_resolvable_host() { return 0; }\n' > "${H}/repo/.claude/scripts/wait_for_resolvable_host.sh"
  : > "${H}/repo/default.nix"
  : > "${H}/repo/.claude/scripts/config_change_digest.R"
  : > "${H}/repo/.claude/scripts/send_config_digest_email.R"
  # nix-shell stub: only the email step's exit status matters.
  cat > "${H}/bin/nix-shell" <<'EOF'
#!/bin/bash
case "$*" in
  *send_config_digest_email*) exit "${STUB_STEP2_EXIT:-0}" ;;
esac
exit 0
EOF
  chmod +x "${H}/bin/nix-shell"
  "${DUCKDB_BIN}" -init /dev/null "${DB}" < "${REPO_ROOT}/.claude/scripts/housekeeping_schema_init.sql" > /dev/null 2>&1
  env -i PATH="$(dirname "${PY_BIN}"):$(dirname "${DUCKDB_BIN}"):/usr/bin:/bin" HOME="${H}" \
      PYENV_ROOT="${PYENV_ROOT:-}" \
      UNIFIED_DB_PATH="${DB}" NIX_SHELL_CMD="${H}/bin/nix-shell" \
      EMAIL_DRY_RUN=1 SKIP_CRON_PULL=1 STUB_STEP2_EXIT="${stub_exit}" \
      bash "${H}/repo/bin/config_digest_cron.sh" > "${H}/stdout.log" 2>&1
  RC=$?
}

status_of() {
  "${DUCKDB_BIN}" -init /dev/null -noheader -list "${DB}" \
    "SELECT status FROM housekeeping_runs WHERE task = 'config_digest' ORDER BY started_at DESC LIMIT 1" 2>/dev/null
}

# Sanity: the harness can see a ledger row at all (otherwise every status check
# below would compare against an empty string and mean nothing).
run_case "ok" 0
st="$(status_of)"
if [ "${RC}" = "0" ] && [ "${st}" = "ok" ]; then
  pass "email exit 0 -> wrapper exit 0, housekeeping status 'ok'"
else
  fail "email exit 0 -> ok" "rc=${RC} status='${st}' out=$(cat "${H}/stdout.log")"
fi

run_case "skip" 10
st="$(status_of)"
if [ "${RC}" = "0" ] && [ "${st}" = "skipped" ]; then
  pass "email exit 10 -> wrapper exit 0, housekeeping status 'skipped'"
else
  fail "email exit 10 -> skipped" "rc=${RC} status='${st}' out=$(cat "${H}/stdout.log")"
fi
if [ -s "${H}/.claude/logs/stamps/config-digest.stamp" ]; then
  pass "a skip still writes the cron_catchup stamp (no spurious catch-up re-run)"
else
  fail "skip writes catch-up stamp" "stamp missing"
fi
if grep -q "SKIP" "${H}/.claude/logs/config_digest_email.log"; then
  pass "a skip is logged as SKIP"
else
  fail "skip is logged" "no SKIP line in log"
fi

run_case "fail" 1
st="$(status_of)"
if [ "${RC}" = "1" ] && [ "${st}" = "failed" ]; then
  pass "email exit 1 -> wrapper exit 1, housekeeping status 'failed' (a failure is not a skip)"
else
  fail "email exit 1 -> failed" "rc=${RC} status='${st}' out=$(cat "${H}/stdout.log")"
fi
if [ ! -e "${H}/.claude/logs/stamps/config-digest.stamp" ]; then
  pass "a failure does not write the catch-up stamp"
else
  fail "failure must not stamp" "stamp exists"
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
