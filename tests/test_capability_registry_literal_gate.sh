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

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
