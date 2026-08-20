#!/usr/bin/env bash
# tests/test_roborev_severity_consistency.sh
#
# Cross-consumer severity-parsing agreement test (llm#974).
#
# Five copies of the "Severity: <level>" parser exist across three
# languages, and they have drifted from each other twice already
# (llm#972 cause 1, llm#974 bypass A/B):
#   1. send_roborev_email.R           — parse_max_severity_ordinal()
#   2. roborev_severity_autoclose.sh  — _parse_max_severity() (main copy)
#   3. roborev_severity_autoclose.sh  — _parse_max_severity() (selftest-local
#      copy; exercised by that script's own ROBOREV_SEVAUTOCLOSE_SELFTEST=1,
#      not re-tested here to avoid a third redundant mechanism)
#   4. roborev_auto_close.sh          — _parse_max_severity() (Python regex)
#   5. roborev_bridge_to_unified.sh   — inline SQL LIKE alternation
#
# This test feeds ONE set of fixture texts (bold markdown form, plain
# no-markup form, no marker at all) through consumers 1, 2, 4, and 5, and
# asserts they all agree on the classification. Consumer 3 (the
# selftest-local copy) is intentionally out of scope here — it is a literal
# textual duplicate of consumer 2 kept in sync by comment convention and
# already covered by roborev_severity_autoclose.sh's own selftest.
#
# Each consumer's function is extracted in isolation (sed/awk between marker
# lines) rather than sourcing the whole script, because sourcing
# roborev_severity_autoclose.sh or roborev_auto_close.sh directly also runs
# their argument-parsing / exit logic at the bottom of the file.
#
# Exits 0 if all consumers agree on all three fixtures AND no consumer was
# skipped, 1 otherwise. A skipped consumer (e.g. the R consumer when
# Rscript is not on PATH, which happens whenever this test runs outside the
# project nix shell) means that consumer's parser went UNVERIFIED — exactly
# the kind of narrowed-scope pass this test exists to catch (llm#746: a
# check that silently checks less than it claims can go green while the
# thing it was meant to catch sits in the part it skipped). The default is
# therefore fail-closed: any skip is a non-zero exit, and the summary names
# which consumer(s) were skipped. Set ALLOW_SKIPPED_CONSUMERS=1 to opt into
# the old lenient behaviour (exit 0 despite skips) for a deliberate local
# partial-coverage run — the summary line still states coverage was
# partial, it never reads like a clean pass.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/../.claude/scripts"
SQLITE3="${SQLITE3:-$(command -v sqlite3 2>/dev/null || echo /usr/bin/sqlite3)}"

PASS=0
FAIL=0
SKIP=0
SKIPPED_NAMES=""
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() {
  echo "SKIP: $1"
  SKIP=$((SKIP + 1))
  SKIPPED_NAMES="${SKIPPED_NAMES:+${SKIPPED_NAMES}; }$1"
}

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# ── Fixture texts ─────────────────────────────────────────────────────────────
# bold  = "**Severity**: High" (the original, always-supported markdown form)
# plain = "Severity: High" (no bold markers — llm#972 cause 1 / llm#974 bypass A/B)
# none  = no "Severity:" marker of any shape at all (llm#972 cause 2 shape)
cat > "${TMP}/bold.txt" <<'EOF'
Review Findings:
- **Severity**: High
- Location: R/foo.R:10
- Problem: something bad.
EOF

cat > "${TMP}/plain.txt" <<'EOF'
Review Findings:
- Severity: High
- Location: R/foo.R:10
- Problem: something bad.
EOF

cat > "${TMP}/none.txt" <<'EOF'
This review discusses the severity of the issue at length, but does not
include a structured severity marker anywhere in its output. Overall
assessment: needs more investigation.
EOF

TEXT_BOLD="$(cat "${TMP}/bold.txt")"
TEXT_PLAIN="$(cat "${TMP}/plain.txt")"
TEXT_NONE="$(cat "${TMP}/none.txt")"

# ── Consumer 2: roborev_severity_autoclose.sh's real _parse_max_severity ─────
# Extract just the two top-level (unindented) function defs so we get zero
# side effects from the rest of the file (argument parsing / exit at the
# bottom would otherwise fire if the whole script were sourced).
SEVAUTO_FN="${TMP}/sevauto_fn.sh"
sed -n '/^_sev_ordinal() {/,/^}/p;/^_parse_max_severity() {/,/^}/p' \
  "${SCRIPTS_DIR}/roborev_severity_autoclose.sh" > "${SEVAUTO_FN}"

if [ -s "${SEVAUTO_FN}" ]; then
  # shellcheck disable=SC1090
  source "${SEVAUTO_FN}"
  sevauto_bold=$(_parse_max_severity "${TEXT_BOLD}")
  sevauto_plain=$(_parse_max_severity "${TEXT_PLAIN}")
  sevauto_none=$(_parse_max_severity "${TEXT_NONE}")
  # This consumer's `_parse_max_severity` returns a numeric ordinal (via
  # `_sev_ordinal`'s off=0/low=1/medium=2/high=3/critical=4 scale) or "" for
  # no match. Normalise to the word form used by the other consumers.
  [ -z "${sevauto_bold}" ] && sevauto_bold="unknown"
  [ -z "${sevauto_plain}" ] && sevauto_plain="unknown"
  [ -z "${sevauto_none}" ] && sevauto_none="unknown"
  case "${sevauto_bold}" in 3) sevauto_bold="high" ;; esac
  case "${sevauto_plain}" in 3) sevauto_plain="high" ;; esac
  case "${sevauto_none}" in 3) sevauto_none="high" ;; esac
  pass "extracted roborev_severity_autoclose.sh functions"
else
  fail "extract roborev_severity_autoclose.sh functions — got empty file"
  sevauto_bold="EXTRACT_FAILED"; sevauto_plain="EXTRACT_FAILED"; sevauto_none="EXTRACT_FAILED"
fi

# ── Consumer 4: roborev_auto_close.sh's _parse_max_severity / _severity_ordinal
AUTOCLOSE_FN="${TMP}/autoclose_fn.sh"
sed -n '/^_parse_max_severity() {/,/^}/p;/^_severity_ordinal() {/,/^}/p' \
  "${SCRIPTS_DIR}/roborev_auto_close.sh" > "${AUTOCLOSE_FN}"

if [ -s "${AUTOCLOSE_FN}" ]; then
  # shellcheck disable=SC1090
  source "${AUTOCLOSE_FN}"
  autoclose_bold=$(_severity_ordinal "$(_parse_max_severity "${TEXT_BOLD}")")
  autoclose_plain=$(_severity_ordinal "$(_parse_max_severity "${TEXT_PLAIN}")")
  autoclose_none=$(_severity_ordinal "$(_parse_max_severity "${TEXT_NONE}")")
  # Normalise this consumer's ordinal scale (High=3) to the word form used
  # by the other shell consumer for comparison.
  case "${autoclose_bold}" in 3) autoclose_bold="high" ;; 0) autoclose_bold="unknown" ;; esac
  case "${autoclose_plain}" in 3) autoclose_plain="high" ;; 0) autoclose_plain="unknown" ;; esac
  case "${autoclose_none}" in 3) autoclose_none="high" ;; 0) autoclose_none="unknown" ;; esac
  pass "extracted roborev_auto_close.sh functions"
else
  fail "extract roborev_auto_close.sh functions — got empty file"
  autoclose_bold="EXTRACT_FAILED"; autoclose_plain="EXTRACT_FAILED"; autoclose_none="EXTRACT_FAILED"
fi

# ── Consumer 1: send_roborev_email.R's parse_max_severity_ordinal ────────────
# A driver .R file (not `Rscript -e "..."`) sidesteps shell-quoting headaches
# from embedding multi-line fixture text inside an -e string.
r_bold="SKIPPED"; r_plain="SKIPPED"; r_none="SKIPPED"
if command -v Rscript >/dev/null 2>&1; then
  R_FN="${TMP}/email_fn.R"
  # Extract the SEVERITY_ORDINAL constant + parse_max_severity_ordinal() def
  # only -- sourcing the whole script requires a JSON snapshot + env setup
  # it does not have here. Anchor the function body on an exact "}"-only
  # line (^}$), not a bare "^}" prefix match -- the latter also matches the
  # "})" line that closes the unrelated AUTOCLOSE_THRESHOLD_STR <- local({})
  # block sitting between the constant and the function, truncating the
  # extraction before the function body.
  {
    grep '^SEVERITY_ORDINAL <- c(' "${SCRIPTS_DIR}/send_roborev_email.R"
    sed -n '/^parse_max_severity_ordinal <- function(text) {/,/^}$/p' \
      "${SCRIPTS_DIR}/send_roborev_email.R"
  } > "${R_FN}"
  if [ -s "${R_FN}" ]; then
    R_DRIVER="${TMP}/driver.R"
    cat > "${R_DRIVER}" <<RSCRIPT
source("${R_FN}")
norm <- function(x) if (is.na(x)) "unknown" else names(SEVERITY_ORDINAL)[SEVERITY_ORDINAL == x]
read_text <- function(f) paste(readLines(f), collapse = "\n")
cat(norm(parse_max_severity_ordinal(read_text("${TMP}/bold.txt"))), "\n", sep = "")
cat(norm(parse_max_severity_ordinal(read_text("${TMP}/plain.txt"))), "\n", sep = "")
cat(norm(parse_max_severity_ordinal(read_text("${TMP}/none.txt"))), "\n", sep = "")
RSCRIPT
    r_out=$(Rscript --vanilla "${R_DRIVER}" 2>&1)
    r_bold=$(printf '%s\n' "${r_out}" | sed -n '1p' | tr -d '[:space:]')
    r_plain=$(printf '%s\n' "${r_out}" | sed -n '2p' | tr -d '[:space:]')
    r_none=$(printf '%s\n' "${r_out}" | sed -n '3p' | tr -d '[:space:]')
    if [ -z "${r_bold}" ] || [ -z "${r_plain}" ] || [ -z "${r_none}" ]; then
      fail "R consumer produced unparseable output: '${r_out}'"
      r_bold="EXTRACT_FAILED"; r_plain="EXTRACT_FAILED"; r_none="EXTRACT_FAILED"
    else
      pass "extracted send_roborev_email.R function"
    fi
  else
    fail "extract send_roborev_email.R parse_max_severity_ordinal — got empty file"
    r_bold="EXTRACT_FAILED"; r_plain="EXTRACT_FAILED"; r_none="EXTRACT_FAILED"
  fi
else
  skip "R consumer (send_roborev_email.R) — Rscript not on PATH"
fi

# ── Consumer 5: roborev_bridge_to_unified.sh's inline SQL LIKE alternation ──
sql_high_open="SKIPPED"; sql_total_open="SKIPPED"
if [ -x "${SQLITE3}" ] || command -v sqlite3 >/dev/null 2>&1; then
  QUERY_FILE="${TMP}/query.sql"
  sed -n '/^_SQLITE_QUERY="$/,/^"$/p' "${SCRIPTS_DIR}/roborev_bridge_to_unified.sh" \
    | sed '1d;$d' > "${QUERY_FILE}"

  if [ -s "${QUERY_FILE}" ]; then
    FIXTURE_DB="${TMP}/fixture.db"
    "${SQLITE3}" "${FIXTURE_DB}" <<'SQL'
CREATE TABLE repos (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TABLE review_jobs (id INTEGER PRIMARY KEY, repo_id INTEGER, finished_at TEXT);
CREATE TABLE reviews (id INTEGER PRIMARY KEY, job_id INTEGER, closed INTEGER, output TEXT, created_at TEXT DEFAULT (datetime('now')));
CREATE TABLE closures (id INTEGER PRIMARY KEY AUTOINCREMENT, finding_id INTEGER, closure_type TEXT, created_at TEXT DEFAULT (datetime('now')));
INSERT INTO repos VALUES (1, 'llm');
INSERT INTO review_jobs VALUES (1, 1, datetime('now'));
SQL
    # Insert the three fixture rows with their literal text (via python3 to
    # avoid sqlite3 CLI multi-line-string quoting headaches).
    /usr/bin/python3 - "${FIXTURE_DB}" "${TMP}/bold.txt" "${TMP}/plain.txt" "${TMP}/none.txt" <<'PY'
import sqlite3, sys
db, bold_f, plain_f, none_f = sys.argv[1:5]
con = sqlite3.connect(db)
for f in (bold_f, plain_f, none_f):
    text = open(f).read()
    con.execute("INSERT INTO reviews (job_id, closed, output) VALUES (1, 0, ?)", (text,))
con.commit()
con.close()
PY

    RESULT="$("${SQLITE3}" -separator '|' "${FIXTURE_DB}" "$(cat "${QUERY_FILE}")" 2>&1)"
    sql_total_open=$(printf '%s' "${RESULT}" | cut -d'|' -f2)
    sql_high_open=$(printf '%s' "${RESULT}" | cut -d'|' -f4)
    if [ -z "${sql_total_open}" ]; then
      fail "SQL consumer query produced no row (got: '${RESULT}')"
      sql_high_open="EXTRACT_FAILED"; sql_total_open="EXTRACT_FAILED"
    else
      pass "extracted + ran roborev_bridge_to_unified.sh query"
    fi
  else
    fail "extract roborev_bridge_to_unified.sh _SQLITE_QUERY — got empty file"
    sql_high_open="EXTRACT_FAILED"; sql_total_open="EXTRACT_FAILED"
  fi
else
  skip "SQL consumer (roborev_bridge_to_unified.sh) — sqlite3 not available"
fi

# ── Assertions: bold form — all consumers must agree it's High ───────────────
echo ""
echo "== bold form (\"**Severity**: High\") =="
[ "${sevauto_bold}" != "SKIPPED" ] && { [ "${sevauto_bold}" = "high" ] && pass "sevauto: bold -> high" || fail "sevauto: bold -> '${sevauto_bold}' (expected high)"; }
[ "${autoclose_bold}" != "SKIPPED" ] && { [ "${autoclose_bold}" = "high" ] && pass "autoclose: bold -> high" || fail "autoclose: bold -> '${autoclose_bold}' (expected high)"; }
if [ "${r_bold}" != "SKIPPED" ]; then
  [ "${r_bold}" = "high" ] && pass "R: bold -> high" || fail "R: bold -> '${r_bold}' (expected high)"
fi
if [ "${sql_high_open}" != "SKIPPED" ]; then
  # bold + plain both classify as High; total_open counts all 3 rows.
  [ "${sql_total_open}" = "3" ] && pass "SQL: total_open -> 3 (all fixture rows counted)" || fail "SQL: total_open -> '${sql_total_open}' (expected 3)"
fi

# ── Assertions: plain form — all consumers must agree it's High (the fix) ────
echo ""
echo "== plain form (\"Severity: High\", no bold markers — llm#974 fix) =="
[ "${sevauto_plain}" != "SKIPPED" ] && { [ "${sevauto_plain}" = "high" ] && pass "sevauto: plain -> high" || fail "sevauto: plain -> '${sevauto_plain}' (expected high — regex must accept plain form)"; }
[ "${autoclose_plain}" != "SKIPPED" ] && { [ "${autoclose_plain}" = "high" ] && pass "autoclose: plain -> high" || fail "autoclose: plain -> '${autoclose_plain}' (expected high — llm#974 Change 1)"; }
if [ "${r_plain}" != "SKIPPED" ]; then
  [ "${r_plain}" = "high" ] && pass "R: plain -> high" || fail "R: plain -> '${r_plain}' (expected high)"
fi
if [ "${sql_high_open}" != "SKIPPED" ]; then
  # Both bold.txt and plain.txt say High -> high_open must count BOTH (=2),
  # proving the plain-form LIKE alternative (llm#974 Change 4) actually matches.
  [ "${sql_high_open}" = "2" ] && pass "SQL: high_open -> 2 (bold + plain both counted)" || fail "SQL: high_open -> '${sql_high_open}' (expected 2 — llm#974 Change 4)"
fi

# ── Assertions: no marker — all consumers must agree it's unknown ────────────
echo ""
echo "== no marker (llm#972 cause 2 shape — must be unknown everywhere) =="
[ "${sevauto_none}" != "SKIPPED" ] && { [ "${sevauto_none}" = "unknown" ] && pass "sevauto: none -> unknown" || fail "sevauto: none -> '${sevauto_none}' (expected unknown)"; }
[ "${autoclose_none}" != "SKIPPED" ] && { [ "${autoclose_none}" = "unknown" ] && pass "autoclose: none -> unknown" || fail "autoclose: none -> '${autoclose_none}' (expected unknown)"; }
if [ "${r_none}" != "SKIPPED" ]; then
  [ "${r_none}" = "unknown" ] && pass "R: none -> unknown" || fail "R: none -> '${r_none}' (expected unknown)"
fi
if [ "${sql_high_open}" != "SKIPPED" ]; then
  # none.txt must not land in high_open: already asserted high_open==2 above
  # (not 3), which is the SQL-side proof that the unmarked fixture is excluded.
  pass "SQL: none-marker fixture excluded from high_open (see high_open==2 assertion above)"
fi

TOTAL=$((PASS + FAIL))
echo ""
if [ "${FAIL}" -ne 0 ]; then
  echo "${PASS}/${TOTAL} PASS — ${FAIL} FAILED (${SKIP} skipped)"
  exit 1
elif [ "${SKIP}" -eq 0 ]; then
  echo "${PASS}/${TOTAL} PASS (0 skipped)"
  exit 0
elif [ "${ALLOW_SKIPPED_CONSUMERS:-0}" = "1" ]; then
  echo "*** PARTIAL COVERAGE — ${SKIP} consumer(s) NOT verified: ${SKIPPED_NAMES} ***"
  echo "*** Cross-consumer agreement is NOT fully proven. Allowed via ALLOW_SKIPPED_CONSUMERS=1. ***"
  echo "${PASS}/${TOTAL} PASS (${SKIP} skipped — coverage partial, see above)"
  exit 0
else
  echo "${PASS}/${TOTAL} PASS, but ${SKIP} consumer(s) went UNVERIFIED: ${SKIPPED_NAMES}"
  echo "Treating unverified consumers as a failure (fail-closed default)."
  echo "Run inside the project nix shell for full coverage, or set ALLOW_SKIPPED_CONSUMERS=1 to explicitly accept partial coverage."
  exit 1
fi
