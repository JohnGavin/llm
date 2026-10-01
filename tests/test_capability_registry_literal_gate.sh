#!/usr/bin/env bash
# tests/test_capability_registry_literal_gate.sh
#
# llm#1294: the capability-registry page hand-typed its own counts ("159
# capabilities ... 72 skills, 12 agents, 75 rules", "of 12 agents", ...) and
# they drifted (the inventory is now 188 / 76 / 12 / 100). One home per value:
# capability_registry_regen.R derives every count from the registry data and
# FAILS the build when a number appears as a bare literal in the template's
# prose or JS strings (escape hatch: data-fixed="<reason>").
#
# This test drives the real generator against a synthetic repo root and a stub
# `duckdb` binary, so it needs neither the live unified.duckdb nor any
# particular inventory size. It needs Rscript + jsonlite, which the CI runner
# lacks (see tests/ci_test_map.tsv, status=skip-ci); when Rscript or jsonlite
# is absent locally it exits 3 (INDETERMINATE), never 0.
#
# Cases:
#   1. shipped template renders against the fixture; every data-fact span is
#      filled with the fixture's true count
#   2. propagation: add one skill to the fixture -> every mention moves
#   3. falsification: each way of re-introducing a literal makes regen exit 1
#
# Exits 0 if all pass, 1 on any failure, 3 if the tooling is unavailable.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REGEN="${REPO_ROOT}/.claude/scripts/capability_registry_regen.R"
TEMPLATE="${REPO_ROOT}/.claude/reports/capability_registry_template.html"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

if ! command -v Rscript >/dev/null 2>&1; then
  echo "INDETERMINATE: Rscript not on PATH; cannot run the generator"
  exit 3
fi
if ! Rscript -e 'quit(status = as.integer(!requireNamespace("jsonlite", quietly = TRUE)))' >/dev/null 2>&1; then
  echo "INDETERMINATE: R package jsonlite not installed; cannot run the generator"
  exit 3
fi

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# ── Fixture repo root: 3 skills, 2 agents, 4 rules ──────────────────────────
FIX="${TMP}/fixture"
mkdir -p "${FIX}/.git" "${FIX}/.claude/skills" "${FIX}/.claude/agents" "${FIX}/.claude/rules"
for s in alpha beta gamma; do
  mkdir -p "${FIX}/.claude/skills/${s}"
  printf -- '---\nname: %s\ndescription: skill %s\n---\nbody\n' "${s}" "${s}" > "${FIX}/.claude/skills/${s}/SKILL.md"
done
for a in fixer critic; do
  printf -- '---\nname: %s\ndescription: agent %s\n---\nbody\n' "${a}" "${a}" > "${FIX}/.claude/agents/${a}.md"
done
for r in r1 r2 r3 r4; do
  printf -- '---\n---\nrule %s\n' "${r}" > "${FIX}/.claude/rules/${r}.md"
done

# ── Stub duckdb: canned answers keyed on the query text ─────────────────────
BIN="${TMP}/bin"
mkdir -p "${BIN}"
cat > "${BIN}/duckdb" <<'EOF'
#!/usr/bin/env bash
q="$*"
case "${q}" in
  *"FROM command_usage WHERE"*|*"FROM command_usage"*GROUP*) echo '[{"command_name":"bye","n":7},{"command_name":"zeta","n":2}]' ;;
  *"COUNT(*) AS n FROM skill_usage"*) echo '[{"n":11}]' ;;
  *"COUNT(*) AS n FROM command_usage"*) echo '[{"n":9}]' ;;
  *"FROM skill_usage"*) echo '[{"skill_name":"alpha","inv":4,"last_used":"2026-01-01"}]' ;;
  *"FROM agent_runs"*) echo '[{"agent_type":"fixer","inv":3,"last_used":"2026-01-02"}]' ;;
  *) echo '[]' ;;
esac
EOF
chmod +x "${BIN}/duckdb"
: > "${TMP}/fake.duckdb"

# run_regen <repo_root> <template> <out>; returns regen's exit status
run_regen() {
  PATH="${BIN}:${PATH}" LLM_REPO_ROOT="$1" \
    Rscript "${REGEN}" --db "${TMP}/fake.duckdb" --template "$2" --out "$3" \
    >"${TMP}/last.log" 2>&1
}

# ── Case 1: shipped template + fixture ──────────────────────────────────────
OUT1="${TMP}/out1.html"
if run_regen "${FIX}" "${TEMPLATE}" "${OUT1}"; then
  pass "shipped template renders against the fixture"
else
  fail "shipped template failed to render: $(cat "${TMP}/last.log")"
fi

fact() { grep -o "data-fact=\"$2\">[^<]*<" "$1" | sed 's/.*>\(.*\)</\1/' | sort -u | tr '\n' ','; }
assert_fact() { # file key expected
  local got; got="$(fact "$1" "$2")"
  if [ "${got}" = "$3," ]; then pass "data-fact ${2} = ${3} everywhere"; else fail "data-fact ${2}: expected '${3},' got '${got}'"; fi
}
assert_fact "${OUT1}" n_skills 3
assert_fact "${OUT1}" n_agents 2
assert_fact "${OUT1}" n_rules 4
assert_fact "${OUT1}" n_total 9
assert_fact "${OUT1}" agents_fired 1
assert_fact "${OUT1}" agents_idle 1
assert_fact "${OUT1}" top_agent fixer
assert_fact "${OUT1}" top_agent_share_pct 100
assert_fact "${OUT1}" cmd_total 9
assert_fact "${OUT1}" skill_usage_rows 11

if grep -q 'data-fact="[A-Za-z_]*"></span>' "${OUT1}"; then
  fail "an empty data-fact span survived rendering"
else
  pass "no unfilled data-fact span in the output"
fi

# the old hand-typed values must be gone from the rendered prose
for stale in '159 capabilities' '72 skills' '75 rules' 'of 12 agents' 'all 159'; do
  if grep -qF "${stale}" "${OUT1}"; then fail "stale literal '${stale}' present in output"; else pass "no stale literal '${stale}'"; fi
done

# ── Case 2: propagation — add a skill, every mention moves ───────────────────
FIX2="${TMP}/fixture2"
cp -R "${FIX}" "${FIX2}"
mkdir -p "${FIX2}/.claude/skills/delta"
printf -- '---\nname: delta\ndescription: skill delta\n---\nbody\n' > "${FIX2}/.claude/skills/delta/SKILL.md"
OUT2="${TMP}/out2.html"
if run_regen "${FIX2}" "${TEMPLATE}" "${OUT2}"; then
  assert_fact "${OUT2}" n_skills 4
  assert_fact "${OUT2}" n_total 10
  N_TOTAL_SPANS="$(grep -o 'data-fact="n_total"' "${TEMPLATE}" | wc -l | tr -d ' ')"
  MOVED="$(grep -o 'data-fact="n_total">10<' "${OUT2}" | wc -l | tr -d ' ')"
  if [ "${N_TOTAL_SPANS}" -ge 2 ] && [ "${N_TOTAL_SPANS}" = "${MOVED}" ]; then
    pass "all ${N_TOTAL_SPANS} n_total mentions moved 9 -> 10"
  else
    fail "n_total mentions: template has ${N_TOTAL_SPANS}, moved ${MOVED}"
  fi
  if grep -q '"n_skills": 4' "${OUT2}" && grep -q '"total": 10' "${OUT2}"; then
    pass "embedded DATA (the source of the JS-derived counts) moved too"
  else
    fail "embedded DATA did not move with the inventory"
  fi
else
  fail "propagation render failed: $(cat "${TMP}/last.log")"
fi

# ── Case 3: falsification — a re-introduced literal must fail the build ──────
expect_gate_fail() { # description sed-expression
  local desc="$1" expr="$2" tpl="${TMP}/bad_template.html" out="${TMP}/bad_out.html"
  rm -f "${out}"
  sed "${expr}" "${TEMPLATE}" > "${tpl}"
  if cmp -s "${tpl}" "${TEMPLATE}"; then fail "${desc}: sed did not change the template (vacuous test)"; return; fi
  run_regen "${FIX}" "${tpl}" "${out}"
  local rc=$?
  if [ "${rc}" -eq 1 ] && [ ! -e "${out}" ] && grep -q 'hand-typed literal' "${TMP}/last.log"; then
    pass "${desc}: regen exit 1, nothing written"
  else
    fail "${desc}: rc=${rc}, out exists=$([ -e "${out}" ] && echo yes || echo no): $(cat "${TMP}/last.log")"
  fi
}
expect_gate_fail 'bare "75 rules" in prose' 's|<span data-fact="n_rules"></span> rules don|75 rules don|'
expect_gate_fail 'bare "159" in heading' 's|all <span data-fact="n_total"></span>, sorted|all 159, sorted|'
expect_gate_fail 'hand-typed value inside a data-fact span' 's|<span data-fact="n_rules"></span> rules don|<span data-fact="n_rules">75</span> rules don|'
expect_gate_fail 'JS string literal "of 12 agents"' "s|' of '+agents.length+' agents · '|' of 12 agents · '|"
expect_gate_fail 'data-fixed with an empty reason' 's|data-fixed="issue reference: an identifier, not a count"|data-fixed=""|'
expect_gate_fail 'unknown data-fact key' 's|data-fact="n_rules"|data-fact="n_rulez"|'

# The escape hatch with a stated reason must pass (case 1 already relies on
# the shipped template's data-fixed spans; assert they are really there).
if [ "$(grep -cE 'data-fixed="[^"]+"' "${TEMPLATE}")" -ge 1 ]; then
  pass "shipped template uses data-fixed with stated reasons (and passed the gate)"
else
  fail "no data-fixed in template: escape hatch untested"
fi

# ── Case 4 (llm#1304): an unreadable DB renders usage as UNKNOWN, never 0 ────
# A locked unified.duckdb used to render agents_fired=0 / cmd_total=0: "could
# not read the usage tables" and "nothing was ever used" produced one page.
# Contract: exit 3 (INDETERMINATE), page still written, every usage-derived
# fact is the em dash, inventory facts stay correct, a visible banner says why.
EMDASH="$(printf '\xe2\x80\x94')"
mk_failing_duckdb() { # dir mode(lock|generic|agents-only) callslog
  mkdir -p "$1"
  cat > "$1/duckdb" <<EOF
#!/usr/bin/env bash
q="\$*"
echo "\${q}" >> "$3"
fail() { echo "\$1" >&2; exit 1; }
mode="$2"
if [ "\${mode}" = "agents-only" ]; then
  case "\${q}" in
    *"FROM agent_runs"*) fail "IO Error: Could not set lock on file: Conflicting lock is held" ;;
  esac
  exec "${BIN}/duckdb" "\$@"
fi
if [ "\${mode}" = "lock" ]; then fail "IO Error: Could not set lock on file: Conflicting lock is held"; fi
fail "Catalog Error: Table with name skill_usage does not exist"
EOF
  chmod +x "$1/duckdb"
}
run_regen_with() { # bindir repo template out
  REGISTRY_DB_RETRY_SLEEP=0 PATH="$1:${PATH}" LLM_REPO_ROOT="$2" \
    Rscript "${REGEN}" --db "${TMP}/fake.duckdb" --template "$3" --out "$4" \
    >"${TMP}/last.log" 2>&1
}
assert_unknown() { # file key
  local got; got="$(fact "$1" "$2")"
  if [ "${got}" = "${EMDASH}," ]; then pass "degraded: data-fact ${2} is unknown (${EMDASH}), not a number"; else fail "degraded: data-fact ${2}: expected '${EMDASH},' got '${got}'"; fi
}

CALLS4="${TMP}/calls_lock.log"
mk_failing_duckdb "${TMP}/bin_lock" lock "${CALLS4}"
OUT4="${TMP}/out4.html"
run_regen_with "${TMP}/bin_lock" "${FIX}" "${TEMPLATE}" "${OUT4}"
RC4=$?
if [ "${RC4}" -eq 3 ]; then pass "locked DB: regen exits 3 (INDETERMINATE)"; else fail "locked DB: expected exit 3, got ${RC4}: $(cat "${TMP}/last.log")"; fi
if [ -s "${OUT4}" ]; then pass "locked DB: page still written (inventory is knowable without the DB)"; else fail "locked DB: no page written"; fi
for k in agents_fired agents_idle top_agent top_agent_share_pct skill_invocations_total cmd_total skill_usage_rows command_usage_rows; do
  assert_unknown "${OUT4}" "${k}"
done
assert_fact "${OUT4}" n_skills 3
assert_fact "${OUT4}" n_agents 2
assert_fact "${OUT4}" n_rules 4
assert_fact "${OUT4}" n_total 9
if grep -q 'data-usage-unreadable' "${OUT4}" && grep -q 'Usage tables unreadable' "${OUT4}"; then
  pass "locked DB: visible 'usage tables unreadable' banner"
else
  fail "locked DB: banner missing"
fi
if grep -qE '"invocations": *[0-9]' "${OUT4}"; then
  fail "locked DB: embedded DATA still carries a numeric invocations value (0 for unknown)"
else
  pass "locked DB: embedded DATA carries no numeric invocation count (null = unknown)"
fi
if grep -q 'Could not set lock' "${TMP}/last.log"; then pass "locked DB: duckdb's stderr reason is surfaced in the log"; else fail "locked DB: stderr reason not surfaced: $(cat "${TMP}/last.log")"; fi
N_AGENT_CALLS="$(grep -c 'FROM agent_runs' "${CALLS4}")"
if [ "${N_AGENT_CALLS}" -eq 3 ]; then pass "locked DB: lock error retried (3 tries)"; else fail "locked DB: expected 3 tries on a lock error, got ${N_AGENT_CALLS}"; fi

CALLS5="${TMP}/calls_generic.log"
mk_failing_duckdb "${TMP}/bin_generic" generic "${CALLS5}"
OUT5="${TMP}/out5.html"
run_regen_with "${TMP}/bin_generic" "${FIX}" "${TEMPLATE}" "${OUT5}"
RC5=$?
if [ "${RC5}" -eq 3 ]; then pass "non-lock DB error: regen exits 3"; else fail "non-lock DB error: expected exit 3, got ${RC5}"; fi
N_GENERIC="$(grep -c 'FROM agent_runs' "${CALLS5}")"
if [ "${N_GENERIC}" -eq 1 ]; then pass "non-lock DB error: not retried"; else fail "non-lock DB error: expected 1 try, got ${N_GENERIC}"; fi

# Partial failure: only agent_runs unreadable -> only agent facts degrade.
mk_failing_duckdb "${TMP}/bin_partial" agents-only "${TMP}/calls_partial.log"
OUT6="${TMP}/out6.html"
run_regen_with "${TMP}/bin_partial" "${FIX}" "${TEMPLATE}" "${OUT6}"
RC6=$?
if [ "${RC6}" -eq 3 ]; then pass "partial failure: regen exits 3"; else fail "partial failure: expected exit 3, got ${RC6}"; fi
assert_unknown "${OUT6}" agents_fired
assert_unknown "${OUT6}" top_agent_share_pct
assert_fact "${OUT6}" skill_invocations_total 4
assert_fact "${OUT6}" cmd_total 9
assert_fact "${OUT6}" skill_usage_rows 11

# A healthy run (case 1) must carry no banner and exit 0.
if grep -q 'data-usage-unreadable' "${OUT1}"; then fail "healthy render carries the unreadable banner"; else pass "healthy render has no unreadable banner"; fi

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
