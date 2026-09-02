#!/usr/bin/env bash
# check_targets_presence.sh — enforce the pipeline-validation rule (Reading C,
# JohnGavin/llm#539): a project without _targets.R is not silently fine.
#
# The prior wording of pipeline-validation only checked parse-validity of
# _targets.R IF the file existed. A project with no _targets.R at all
# satisfied that check trivially — parse() was never called, so nothing could
# fail. This script closes that gap by distinguishing FOUR states instead of
# the old two, per the checks-must-distinguish-unknown rule:
#
#   STATE                          RESULT              EXIT
#   _targets.R present, parses     PASS                0
#   _targets.R present, parse fail FAIL parse-error     1
#   _targets.R absent, exempt      PASS exempt          0
#   _targets.R absent, undeclared  FAIL undeclared       2   <- the bug this
#                                                              script exists
#                                                              to catch
#   usage error (bad path, no R)   INDETERMINATE         3
#
# Exit 2 is deliberately distinct from exit 1 so a caller can tell "the
# pipeline is broken" apart from "there is no pipeline and nobody said why".
# Exit 3 (tool/path problems) is never folded into either FAIL state.
#
# EXEMPTION SYNTAX — a table row in the project's .claude/CLAUDE.md:
#
#   | Targets pipeline | none — <reason> |
#
# Mirrors the `| Environment | dev |` convention in permission-discipline
# Part 3. <reason> must be non-empty — a bare "none —" with nothing after the
# dash is treated as undeclared (a placeholder is a defect, not a reason;
# see checks-must-distinguish-unknown's placeholder corollary).
#
# Usage:
#   check_targets_presence.sh [project-dir]     # default: cwd
#   check_targets_presence.sh --selftest
#
# JohnGavin/llm#539

set -uo pipefail

SELFTEST=0
TARGET_DIR="."

usage() {
    echo "Usage: $(basename "$0") [project-dir]" >&2
    echo "       $(basename "$0") --selftest" >&2
}

while [ $# -gt 0 ]; do
    case "$1" in
        (--selftest) SELFTEST=1; shift ;;
        (-h|--help)  usage; exit 3 ;;
        (*)          TARGET_DIR="$1"; shift ;;
    esac
done

# Exemption row: a markdown table line naming "Targets pipeline", "none",
# a dash (ASCII "-" or em-dash "—"), and at least one alphanumeric character
# after it (the reason). grep -i handles case; the character class handles
# either dash form.
EXEMPT_RE='^\|[[:space:]]*targets[[:space:]]+pipeline[[:space:]]*\|[[:space:]]*none[[:space:]]*[-—][[:space:]]*[a-zA-Z0-9].*\|[[:space:]]*$'

# check_one — inspect one project directory. Prints one summary line.
# Returns 0 pass / 1 parse-fail / 2 undeclared-absence / 3 usage-error.
check_one() {
    local dir="$1"
    if [ ! -d "$dir" ]; then
        echo "INDETERMINATE usage: not a directory: $dir"
        return 3
    fi
    local targets_file="$dir/_targets.R"
    local claude_md="$dir/.claude/CLAUDE.md"

    if [ -f "$targets_file" ]; then
        if ! command -v Rscript >/dev/null 2>&1; then
            echo "INDETERMINATE usage: Rscript not on PATH — cannot check parse validity of $targets_file"
            return 3
        fi
        local out rc=0
        out="$(Rscript --vanilla -e '
            args <- commandArgs(trailingOnly = TRUE)
            res <- tryCatch({ parse(args[1]); "OK" },
                             error = function(e) paste("PARSE_ERROR:", conditionMessage(e)))
            cat(res, "\n")
            if (res != "OK") quit(status = 1) else quit(status = 0)
        ' "$targets_file" 2>&1)" || rc=$?
        if [ "$rc" -ne 0 ]; then
            echo "FAIL parse-error: $targets_file: $out"
            return 1
        fi
        echo "PASS parses: $targets_file"
        return 0
    fi

    # _targets.R absent — is the absence declared?
    if [ -f "$claude_md" ] && grep -iE "$EXEMPT_RE" "$claude_md" >/dev/null 2>&1; then
        local reason
        reason="$(grep -iE "$EXEMPT_RE" "$claude_md" | head -1)"
        echo "PASS exempt: $dir — declared: ${reason}"
        return 0
    fi

    echo "FAIL undeclared-absence: $dir has no _targets.R and no '| Targets pipeline | none — <reason> |' row in .claude/CLAUDE.md"
    return 2
}

selftest() {
    local tmp pass=0 fail=0
    tmp="$(mktemp -d)"
    ok(){ pass=$((pass+1)); echo "  PASS: $1"; }
    bad(){ fail=$((fail+1)); echo "  FAIL: $1"; }
    echo "check_targets_presence.sh --selftest"

    # State 1: _targets.R present, parses cleanly -> PASS (exit 0).
    if command -v Rscript >/dev/null 2>&1; then
        mkdir -p "$tmp/state1"
        cat > "$tmp/state1/_targets.R" <<'EOS'
library(targets)
list(
  tar_target(x, 1 + 1)
)
EOS
        out="$(check_one "$tmp/state1")"; rc=$?
        if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^PASS parses'; then
            ok "state 1: valid _targets.R -> PASS (exit 0)"
        else
            bad "state 1: expected PASS/exit0, got rc=$rc out=$out"
        fi

        # State 2: _targets.R present, syntactically broken -> FAIL (exit 1).
        # This is the case the ORIGINAL rule ("parse() MUST succeed") already
        # covered -- must still be caught after this rewrite.
        mkdir -p "$tmp/state2"
        cat > "$tmp/state2/_targets.R" <<'EOS'
list(
  tar_target(x, 1 +
EOS
        out="$(check_one "$tmp/state2")"; rc=$?
        if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '^FAIL parse-error'; then
            ok "state 2: malformed _targets.R -> FAIL parse-error (exit 1)"
        else
            bad "state 2: expected FAIL/exit1, got rc=$rc out=$out"
        fi
    else
        echo "  SKIP: states 1-2 need Rscript on PATH (not available in this shell)"
    fi

    # State 3: _targets.R absent, exemption declared -> PASS exempt (exit 0).
    mkdir -p "$tmp/state3/.claude"
    cat > "$tmp/state3/.claude/CLAUDE.md" <<'EOS'
# project

| Field | Value |
|-------|-------|
| Environment | dev |
| Targets pipeline | none — local git-only knowledge base, no build artifacts |
EOS
    out="$(check_one "$tmp/state3")"; rc=$?
    if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^PASS exempt'; then
        ok "state 3: declared exemption -> PASS exempt (exit 0)"
    else
        bad "state 3: expected PASS exempt/exit0, got rc=$rc out=$out"
    fi

    # State 4 -- THE BUG THIS SCRIPT EXISTS TO CATCH: _targets.R absent, no
    # exemption declared at all -> must be FAIL, never a silent pass. This is
    # the falsification the verification-before-completion rule requires: a
    # checker that returns PASS on an empty/undeclared directory reproduces
    # the exact vacuous-pass bug from JohnGavin/llm#539.
    mkdir -p "$tmp/state4"
    out="$(check_one "$tmp/state4")"; rc=$?
    if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q '^FAIL undeclared-absence'; then
        ok "state 4: no _targets.R, no exemption -> FAIL undeclared-absence (exit 2), NOT a silent pass"
    else
        bad "state 4 (THE llm#539 BUG): expected FAIL undeclared-absence/exit2, got rc=$rc out=$out -- a PASS here reproduces the original defect"
    fi

    # State 4b -- CLAUDE.md exists but has no Targets pipeline row at all ->
    # still undeclared, must FAIL the same way as no CLAUDE.md.
    mkdir -p "$tmp/state4b/.claude"
    cat > "$tmp/state4b/.claude/CLAUDE.md" <<'EOS'
# project

| Field | Value |
|-------|-------|
| Environment | dev |
EOS
    out="$(check_one "$tmp/state4b")"; rc=$?
    if [ "$rc" -eq 2 ]; then
        ok "state 4b: CLAUDE.md present but no Targets pipeline row -> FAIL undeclared-absence"
    else
        bad "state 4b: expected exit2, got rc=$rc out=$out"
    fi

    # State 4c -- a placeholder exemption (empty reason) must NOT count as
    # declared. Per checks-must-distinguish-unknown's placeholder corollary,
    # an unfilled placeholder is a defect, not a satisfied exemption.
    mkdir -p "$tmp/state4c/.claude"
    cat > "$tmp/state4c/.claude/CLAUDE.md" <<'EOS'
| Targets pipeline | none — |
EOS
    out="$(check_one "$tmp/state4c")"; rc=$?
    if [ "$rc" -eq 2 ]; then
        ok "state 4c: empty-reason placeholder -> FAIL undeclared-absence, not a pass"
    else
        bad "state 4c: expected exit2 on empty-reason placeholder, got rc=$rc out=$out"
    fi

    # Usage error: nonexistent directory -> exit 3, distinct from both FAIL
    # states above (checks-must-distinguish-unknown: never fold a tool/path
    # problem into a content finding).
    out="$(check_one "$tmp/does-not-exist")"; rc=$?
    if [ "$rc" -eq 3 ]; then
        ok "usage error: nonexistent directory -> exit 3, distinct from content FAILs"
    else
        bad "usage error: expected exit3, got rc=$rc out=$out"
    fi

    rm -rf "$tmp"
    echo "  $pass passed, $fail failed"
    [ "$fail" -eq 0 ]
}

[ "$SELFTEST" -eq 1 ] && { selftest; exit $?; }

check_one "$TARGET_DIR"
exit $?
