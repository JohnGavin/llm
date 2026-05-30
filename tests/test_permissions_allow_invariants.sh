#!/usr/bin/env bash
# tests/test_permissions_allow_invariants.sh
# Asserts invariants on .claude/settings.json permissions.allow list.
# Exit 0 = all pass. Exit 1 = at least one failure.
set -uo pipefail

SETTINGS="${1:-.claude/settings.json}"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# Helper: check if string is in allow list
in_allow() {
    python3 - "$SETTINGS" "$1" << 'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
allow = d['permissions']['allow']
print(1 if sys.argv[2] in allow else 0)
EOF
}

# Helper: get allow count
allow_count() {
    python3 - "$SETTINGS" << 'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
print(len(d['permissions']['allow']))
EOF
}

# (a) JSON parses
if python3 -m json.tool "$SETTINGS" > /dev/null 2>&1; then
    pass "JSON is valid"
else
    fail "JSON parse error in $SETTINGS"
fi

# (b) No banned patterns (strict no-return list per llm#188)
declare -a BANNED=(
    "Bash(/bin/bash *)"
    "Bash(/usr/bin/env bash *)"
    "Bash(/bin:*)"
    "Bash(/usr/bin:*)"
    "Bash(/nix/store:*)"
    "Bash(bash:*)"
    "Bash(security dump-keychain:*)"
)

for b in "${BANNED[@]}"; do
    count=$(in_allow "$b")
    if [ "$count" -eq 0 ]; then
        pass "Banned pattern absent: $b"
    else
        fail "BANNED pattern PRESENT: $b"
    fi
done

# (c) Shell keyword leaks not present
declare -a KEYWORDS=("Bash(do)" "Bash(done:*)" "Bash(fi:*)" "Bash(then:*)" "Bash(else:*)" "Bash(if:*)" "Bash(while:*)")
for kw in "${KEYWORDS[@]}"; do
    count=$(in_allow "$kw")
    if [ "$count" -eq 0 ]; then
        pass "Shell-keyword absent: $kw"
    else
        fail "Shell-keyword LEAK: $kw"
    fi
done

# (d) __NEW_LINE__ artifacts not present
nl_count=$(python3 - "$SETTINGS" << 'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
allow = d['permissions']['allow']
print(sum(1 for e in allow if '__NEW_LINE_' in e))
EOF
)
if [ "$nl_count" -eq 0 ]; then
    pass "No __NEW_LINE__ artifacts"
else
    fail "__NEW_LINE__ artifacts present: $nl_count"
fi

# (e) Count is <= 350 (generous upper bound — consolidation target is ~300)
count=$(allow_count)
if [ "$count" -le 350 ]; then
    pass "Entry count $count <= 350"
else
    fail "Entry count $count EXCEEDS 350 — consolidation needed"
fi

# (f) Known-good invocations still present
declare -a KNOWN_GOOD=(
    "Bash(git:*)"
    "Bash(gh:*)"
    "Bash(Rscript:*)"
    "Bash(roborev:*)"
    "Bash(/usr/local/bin/roborev close:*)"
    "Bash(sqlite3:*)"
    "Bash(python3:*)"
    "Bash(nix-shell:*)"
    "Bash(timeout:*)"
    "WebSearch"
    "Write"
)
for kg in "${KNOWN_GOOD[@]}"; do
    count=$(in_allow "$kg")
    if [ "$count" -gt 0 ]; then
        pass "Known-good present: $kg"
    else
        fail "Known-good MISSING: $kg"
    fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
