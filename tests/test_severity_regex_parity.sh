#!/usr/bin/env bash
# tests/test_severity_regex_parity.sh
#
# JohnGavin/llm#1146 item 2 — "stop maintaining three copies" of the
# Severity-marker parser.
#
# roborev_merge_gate.sh's own copy of the regex has been removed (llm#1146):
# it now imports .claude/scripts/lib/roborev_classify.py directly, which is
# the single canonical Python implementation. That still leaves TWO
# genuinely separate copies that cannot cheaply share one implementation
# across languages (see roborev_classify.py's own module docstring for why
# — R and Python/bash cannot cheaply share one implementation here):
#
#   - .claude/scripts/roborev_severity_autoclose.sh's `_parse_max_severity()`
#     (bash, grep -iE) — and its own SELFTEST-local duplicate of the same
#     function, which is a THIRD copy living inside the SAME file
#   - .claude/scripts/send_roborev_email.R's `parse_max_severity_ordinal()`
#     (R, perl-mode regex)
#
# Per llm#1146's instruction ("if a single shared source is genuinely
# impractical across bash/python/R, ... add a test that FAILS when the
# copies diverge"): this test extracts each implementation's literal
# function body directly from its source file (never re-typed by hand, so
# it cannot itself silently drift from what ships) and runs the SAME
# fixture set through Python (canonical), R, and bash (both the production
# and the selftest-local bash copies), asserting all four agree.
#
# Exits 0 if all tests pass, 1 on any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CLASSIFY_MODULE="${REPO_ROOT}/.claude/scripts/lib/roborev_classify.py"
AUTOCLOSE_SCRIPT="${REPO_ROOT}/.claude/scripts/roborev_severity_autoclose.sh"
EMAIL_SCRIPT="${REPO_ROOT}/.claude/scripts/send_roborev_email.R"
PYTHON="${PYTHON:-/usr/bin/python3}"
RSCRIPT="${RSCRIPT:-Rscript}"

PASS=0
FAIL=0
TMPDIR_ROOT="$(mktemp -d /tmp/test_sev_parity_XXXXXX)"
cleanup() { rm -rf "${TMPDIR_ROOT}"; }
trap cleanup EXIT

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "${expected}" = "${actual}" ]; then
        pass "${desc}"
    else
        fail "${desc} — expected='${expected}' actual='${actual}'"
    fi
}

# ── Preconditions: source files exist ──────────────────────────────────────
for f in "${CLASSIFY_MODULE}" "${AUTOCLOSE_SCRIPT}" "${EMAIL_SCRIPT}"; do
  if [ ! -f "${f}" ]; then
    fail "precondition: ${f} exists"
  else
    pass "precondition: ${f} exists"
  fi
done

# ── Extract the REAL (non-selftest) bash implementation ────────────────────
BASH_REAL_SNIPPET="${TMPDIR_ROOT}/bash_real.sh"
awk '
BEGIN { in_selftest=0; done_selftest=0; grab=0; in_pms=0 }
/^if \[ "\$\{ROBOREV_SEVAUTOCLOSE_SELFTEST:-0\}" = "1" \]; then$/ { in_selftest=1 }
in_selftest && /^fi$/ { in_selftest=0; done_selftest=1; next }
!done_selftest { next }
/^_sev_ordinal\(\) \{/ { grab=1 }
grab { print }
grab && /^_parse_max_severity\(\) \{/ { in_pms=1 }
in_pms && /^}$/ { exit }
' "${AUTOCLOSE_SCRIPT}" > "${BASH_REAL_SNIPPET}"

if [ -s "${BASH_REAL_SNIPPET}" ] && grep -q "_parse_max_severity" "${BASH_REAL_SNIPPET}"; then
  pass "extracted the production (non-selftest) bash _parse_max_severity()"
else
  fail "extracted the production (non-selftest) bash _parse_max_severity() — extraction produced nothing; awk pattern drifted from roborev_severity_autoclose.sh"
fi

# ── Extract the SELFTEST-local bash implementation (the file's own 3rd copy) ─
# Indented (it lives inside the `if [ ...SELFTEST... ]; then` block), so the
# start/end markers tolerate leading whitespace.
BASH_SELFTEST_SNIPPET="${TMPDIR_ROOT}/bash_selftest.sh"
awk '
/^if \[ "\$\{ROBOREV_SEVAUTOCLOSE_SELFTEST:-0\}" = "1" \]; then$/ { in_selftest=1; next }
in_selftest && /^fi$/ { exit }
in_selftest && /^[[:space:]]*_sev_ordinal\(\) \{/ { grab=1 }
in_selftest && grab { print }
in_selftest && grab && /^[[:space:]]*_parse_max_severity\(\) \{/ { in_pms=1 }
in_selftest && in_pms && /^[[:space:]]*\}$/ { exit }
' "${AUTOCLOSE_SCRIPT}" > "${BASH_SELFTEST_SNIPPET}"

if [ -s "${BASH_SELFTEST_SNIPPET}" ] && grep -q "_parse_max_severity" "${BASH_SELFTEST_SNIPPET}"; then
  pass "extracted the SELFTEST-local bash _parse_max_severity() (3rd copy)"
else
  fail "extracted the SELFTEST-local bash _parse_max_severity() (3rd copy) — extraction produced nothing; awk pattern drifted"
fi

# ── Extract the R implementation ────────────────────────────────────────────
R_SNIPPET="${TMPDIR_ROOT}/r_real.R"
awk '
/^SEVERITY_ORDINAL <- c\(critical/ { grab=1 }
grab { print }
grab && /^parse_max_severity_ordinal <- function/ { infunc=1 }
infunc && /^}$/ { exit }
' "${EMAIL_SCRIPT}" > "${R_SNIPPET}"

if [ -s "${R_SNIPPET}" ] && grep -q "parse_max_severity_ordinal" "${R_SNIPPET}"; then
  pass "extracted send_roborev_email.R's parse_max_severity_ordinal()"
else
  fail "extracted send_roborev_email.R's parse_max_severity_ordinal() — extraction produced nothing; awk pattern drifted from send_roborev_email.R"
fi

# ── Fixture set: text -> expected ordinal ("" means "no marker found") ─────
# critical=4 high=3 medium=2 low=1
FIXTURES_DESC=(
  "bold '**Severity**: High'"
  "non-bold 'Severity: High' (llm#972 cause 1 / llm#1146 proof text)"
  "no leading dash, no bold: 'Severity: High'"
  "lowercase word: '- severity: critical'"
  "prose mentioning 'severity' with no colon-anchored marker"
  "multiple markers -> takes the max (Low then High)"
  "empty string"
)
FIXTURES_TEXT=(
  "- **Severity**: High"
  "- Severity: High"
  "Severity: High"
  "- severity: critical"
  "This review discusses the severity of the issue at length, but does not include a structured marker."
  $'- **Severity**: Low\n- **Severity**: High'
  ""
)
FIXTURES_EXPECTED=(
  "3"
  "3"
  "3"
  "4"
  ""
  "3"
  ""
)

run_python() {
  "${PYTHON}" -c "
import sys
sys.path.insert(0, '$(dirname "${CLASSIFY_MODULE}")')
from roborev_classify import parse_max_severity_ordinal
r = parse_max_severity_ordinal(sys.argv[1])
print('' if r is None else r)
" "$1"
}

run_r() {
  # NOTE: no `--args` here -- with `Rscript -e`, `--args` itself lands in
  # commandArgs(trailingOnly=TRUE) instead of being stripped as a separator
  # (that stripping only happens when a script FILE precedes the args, per
  # R's own docs). Passing the fixture text as a bare trailing argument
  # works correctly in `-e` mode; verified directly before relying on it.
  "${RSCRIPT}" -e "
source('${R_SNIPPET}')
r <- parse_max_severity_ordinal(commandArgs(trailingOnly = TRUE)[1])
cat(if (is.na(r)) '' else as.character(r))
" "$1" 2>/dev/null
}

run_bash_real() {
  bash -c "
source '${BASH_REAL_SNIPPET}'
_parse_max_severity \"\$1\"
" _ "$1"
}

run_bash_selftest() {
  bash -c "
source '${BASH_SELFTEST_SNIPPET}'
_parse_max_severity \"\$1\"
" _ "$1"
}

# ── Run every fixture through all four implementations ─────────────────────
HAVE_RSCRIPT=1
command -v "${RSCRIPT}" >/dev/null 2>&1 || HAVE_RSCRIPT=0
if [ "${HAVE_RSCRIPT}" = "0" ]; then
  fail "Rscript not on PATH — cannot verify R implementation parity (run inside the project nix shell)"
fi

for i in "${!FIXTURES_TEXT[@]}"; do
  desc="${FIXTURES_DESC[$i]}"
  text="${FIXTURES_TEXT[$i]}"
  expected="${FIXTURES_EXPECTED[$i]}"

  py_out=$(run_python "${text}")
  assert_eq "python (canonical): ${desc}" "${expected}" "${py_out}"

  bash_out=$(run_bash_real "${text}")
  assert_eq "bash (production): ${desc}" "${expected}" "${bash_out}"

  bashst_out=$(run_bash_selftest "${text}")
  assert_eq "bash (selftest-local 3rd copy): ${desc}" "${expected}" "${bashst_out}"

  if [ "${HAVE_RSCRIPT}" = "1" ]; then
    r_out=$(run_r "${text}")
    assert_eq "R: ${desc}" "${expected}" "${r_out}"
  fi
done

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Results: ${PASS} PASS, ${FAIL} FAIL"

if [ "${FAIL}" -gt 0 ]; then
  exit 1
fi
exit 0
