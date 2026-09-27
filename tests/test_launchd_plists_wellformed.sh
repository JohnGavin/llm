#!/usr/bin/env bash
# tests/test_launchd_plists_wellformed.sh — strict-XML-well-formedness check
# for every committed launchd plist (JohnGavin/llm#1136 follow-up).
#
# macOS's own tooling (plutil, launchctl) tolerates a literal "--" inside an
# XML comment even though the XML spec forbids it (comments MUST NOT contain
# the two-character sequence "--" anywhere in their body). A strict XML
# parser (Python's plistlib, which uses expat under the hood; also
# `xmllint --noout`) rejects it. Six plists were found with this defect on
# 2026-09-27 (same class as the fix in commit 7d73439a / PR referencing
# JohnGavin/llm#1136): a hand-written comment used "--" as a prose dash or
# pasted a "--flag" CLI example verbatim. Nothing caught it because the only
# validation ever run against these files was plutil/launchctl, which is
# permissive. This script closes that gap.
#
# Checks every *.plist, *.plist.template, and *.plist.deprecated-* file
# under .claude/launchd/ (installed vs. templated vs. retired — all three
# are still committed, parseable XML and should stay well-formed).
#
# Exit codes (exit-code-conventions rule, JohnGavin/llm#1140):
#   0 = PASS        — every file parsed cleanly
#   1 = FAIL        — one or more files are not well-formed XML (bad file +
#                      line/column named in the output)
#   2 = usage error — bad CLI arguments
#   3 = INDETERMINATE — could not run the check at all (no python3 on PATH,
#                      or the launchd directory does not exist)
#
# Usage:
#   tests/test_launchd_plists_wellformed.sh [launchd-dir]   # default: <repo>/.claude/launchd
#   tests/test_launchd_plists_wellformed.sh --selftest
#
# --selftest falsifies the check itself (verification-before-completion: "a
# check you have never seen fail is not a check"): it plants a file
# containing a forbidden "--" inside an XML comment in a throwaway temp
# directory and asserts this script exits 1 and names the bad file+line,
# then re-runs the same script against the real, fixed .claude/launchd/ tree
# and asserts it exits 0.

set -uo pipefail

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_LAUNCHD_DIR="$REPO_ROOT/.claude/launchd"

usage() {
    cat <<'EOF'
Usage: test_launchd_plists_wellformed.sh [launchd-dir]
       test_launchd_plists_wellformed.sh --selftest

Strict-XML-parses every *.plist, *.plist.template, and *.plist.deprecated-*
file under the given directory (default: .claude/launchd/ under the repo
root) and reports any that are not well-formed XML.

Exit codes: 0 pass, 1 fail, 2 usage error, 3 indeterminate (cannot run).
EOF
}

# ── Core check: strict-parse every plist-shaped file in a directory ────────
# Prints PASS/FAIL lines to stdout; returns 0 (all clean), 1 (>=1 failure),
# or 3 (indeterminate: python3 missing or directory absent).
check_dir() {
    local dir="$1"

    if ! command -v python3 >/dev/null 2>&1; then
        echo "INDETERMINATE: python3 not on PATH — cannot strict-parse plists in $dir"
        return 3
    fi

    if [ ! -d "$dir" ]; then
        echo "INDETERMINATE: directory not found: $dir"
        return 3
    fi

    python3 - "$dir" <<'PYEOF'
import glob
import os
import plistlib
import sys

directory = sys.argv[1]
patterns = ["*.plist", "*.plist.template", "*.plist.deprecated-*"]
files = []
for p in patterns:
    files.extend(glob.glob(os.path.join(directory, p)))
files = sorted(set(files))

if not files:
    print(f"INDETERMINATE: no *.plist/*.plist.template files found under {directory}")
    sys.exit(3)

bad = []
for f in files:
    with open(f, "rb") as fh:
        try:
            plistlib.load(fh)
        except Exception as e:
            bad.append((f, str(e)))

print(f"checked {len(files)} file(s) under {directory}")
if bad:
    for f, err in bad:
        print(f"FAIL: {f}: {err}")
    print(f"FAIL: {len(bad)}/{len(files)} file(s) not well-formed XML")
    sys.exit(1)

print(f"PASS: all {len(files)} file(s) are well-formed XML")
sys.exit(0)
PYEOF
    return $?
}

# ── Self-test: falsify the check before trusting it ─────────────────────────
run_selftest() {
    local tmp bad_file good_pass=0 bad_fail=0

    if ! command -v python3 >/dev/null 2>&1; then
        echo "INDETERMINATE: python3 not on PATH — cannot run selftest"
        return 3
    fi

    tmp="$(mktemp -d "${TMPDIR:-/tmp}/launchd_wellformed_selftest_XXXXXX")"
    trap 'rm -rf "$tmp"' RETURN

    # Case 1: a file with a forbidden "--" inside an XML comment MUST fail.
    bad_file="$tmp/com.example.bad.plist"
    cat > "$bad_file" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- a -- b -->
    <key>Label</key>
    <string>com.example.bad</string>
</dict>
</plist>
EOF

    if out="$(bash "$SCRIPT_PATH" "$tmp" 2>&1)"; then
        echo "  FAIL (selftest case 1): expected exit 1 on a comment containing '--', got exit 0"
        echo "$out" | sed 's/^/    /'
        bad_fail=1
    else
        rc=$?
        if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "com.example.bad.plist"; then
            echo "  PASS (selftest case 1): planted '<!-- a -- b -->' correctly FAILs (exit 1), names the file"
        else
            echo "  FAIL (selftest case 1): expected exit 1 naming the bad file, got rc=$rc"
            echo "$out" | sed 's/^/    /'
            bad_fail=1
        fi
    fi

    # Case 2: the same file, with the offending comment fixed, MUST pass.
    fixed_file="$tmp/com.example.good.plist"
    cat > "$fixed_file" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- a - b (em dash or single hyphen, never a literal double hyphen) -->
    <key>Label</key>
    <string>com.example.good</string>
</dict>
</plist>
EOF
    rm -f "$bad_file"
    if out="$(bash "$SCRIPT_PATH" "$tmp" 2>&1)"; then
        echo "  PASS (selftest case 2): with the bad file removed, the fixed-comment tree passes (exit 0)"
    else
        echo "  FAIL (selftest case 2): expected exit 0 once the '--' comment is fixed"
        echo "$out" | sed 's/^/    /'
        bad_fail=1
    fi

    # Case 3: the real, currently-committed .claude/launchd/ tree MUST pass.
    if out="$(bash "$SCRIPT_PATH" "$DEFAULT_LAUNCHD_DIR" 2>&1)"; then
        echo "  PASS (selftest case 3): the real .claude/launchd/ tree passes (exit 0)"
        good_pass=1
    else
        echo "  FAIL (selftest case 3): expected the real .claude/launchd/ tree to pass, it did not"
        echo "$out" | sed 's/^/    /'
        bad_fail=1
    fi

    rm -rf "$tmp"
    trap - RETURN

    if [ "$bad_fail" -ne 0 ] || [ "$good_pass" -ne 1 ]; then
        echo "SELFTEST: FAIL"
        return 1
    fi
    echo "SELFTEST: PASS (3/3)"
    return 0
}

# ── Entry point ───────────────────────────────────────────────────────────
main() {
    if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
        usage
        exit 2
    fi

    if [ "${1:-}" = "--selftest" ]; then
        run_selftest
        exit $?
    fi

    if [ "$#" -gt 1 ]; then
        usage
        exit 2
    fi

    local dir="${1:-$DEFAULT_LAUNCHD_DIR}"
    check_dir "$dir"
    exit $?
}

main "$@"
