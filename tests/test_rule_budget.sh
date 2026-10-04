#!/usr/bin/env bash
# tests/test_rule_budget.sh — always-loaded instruction budget (check E).
#
# check_rule_scoping.sh --budget measures the chars that load into every
# session against Claude Code's startup limit; rule_scoping_precommit.sh gates
# commits on it. This wrapper:
#   1. runs both scripts' own --selftest suites and requires them to pass;
#   2. FALSIFIES the budget check (a green result only means something if red
#      was reachable): a temp copy of the checker whose "paths: ['**'] still
#      loads everywhere" rule is broken must FAIL its own selftest;
#   3. confirms --budget against a missing global CLAUDE.md is exit 3
#      (indeterminate), never 0.
#
# Usage: bash tests/test_rule_budget.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKER="$REPO_ROOT/.claude/scripts/check_rule_scoping.sh"
PRECOMMIT="$REPO_ROOT/.claude/scripts/rule_scoping_precommit.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()   { echo "ok     $*"; PASS=$((PASS+1)); }
fail() { echo "FAIL   $*"; FAIL=$((FAIL+1)); }

if bash "$CHECKER" --selftest >"$TMP/checker.out" 2>&1; then
    ok "check_rule_scoping.sh --selftest passes ($(tail -1 "$TMP/checker.out"))"
else
    fail "check_rule_scoping.sh --selftest ($(tail -3 "$TMP/checker.out" | tr '\n' ' '))"
fi

if bash "$PRECOMMIT" --selftest >"$TMP/pre.out" 2>&1; then
    ok "rule_scoping_precommit.sh --selftest passes ($(tail -1 "$TMP/pre.out"))"
else
    fail "rule_scoping_precommit.sh --selftest ($(tail -3 "$TMP/pre.out" | tr '\n' ' '))"
fi

# Falsification: break the '**'-is-always-loaded rule in a COPY.
sed "s/^ALWAYS_STAR = .*/ALWAYS_STAR = \"__never_matches__\"/" "$CHECKER" > "$TMP/mutant.sh"
if cmp -s "$CHECKER" "$TMP/mutant.sh"; then
    fail "mutation did not change the checker (ALWAYS_STAR line not found) — falsification is vacuous"
else
    if bash "$TMP/mutant.sh" --selftest >"$TMP/mutant.out" 2>&1; then
        fail "mutant (paths:[\"**\"] treated as scoped) still passed its selftest — the check cannot go red"
    elif grep -q "FAIL: budget: GLOBAL line" "$TMP/mutant.out"; then
        ok "falsified: treating paths:[\"**\"] as scoped turns the GLOBAL-count case red"
    else
        fail "mutant failed, but not on the expected case: $(head -3 "$TMP/mutant.out" | tr '\n' ' ')"
    fi
fi

# Indeterminate: a HOME with no ~/.claude/CLAUDE.md must be exit 3.
mkdir -p "$TMP/emptyhome/.claude/rules" "$TMP/emptyhome/docs_gh"
RULE_BUDGET_HOME="$TMP/emptyhome" RULE_BUDGET_DOCS="$TMP/emptyhome/docs_gh" \
    bash "$CHECKER" --budget >"$TMP/indet.out" 2>&1
rc=$?
if [ "$rc" -eq 3 ] && grep -q "RULE-BUDGET-INDETERMINATE" "$TMP/indet.out"; then
    ok "--budget with no global CLAUDE.md -> exit 3 and says INDETERMINATE"
else
    fail "--budget with no global CLAUDE.md: rc=$rc out=$(head -2 "$TMP/indet.out" | tr '\n' ' ')"
fi

echo ""
echo "test_rule_budget: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
