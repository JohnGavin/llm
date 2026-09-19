#!/usr/bin/env bash
# pruned_script_consumer_check.sh — pre-deletion consumer check (llm#1067)
#
# AGENTS.md's "Simplicity — subtractive-first" section already says:
# "Before deleting anything from .claude/scripts/, bin/, or
# .claude/templates/, run grep -rl <basename> ~/docs_gh/ — 'unused' must be
# verified by grepping consumers across every project, never by inspection
# alone." That sentence was added AFTER #773 deleted
# verify_mermaid_dashboard.sh, which a downstream project's post-render.sh
# still called by absolute path — the breakage ran silently for six weeks
# because the call site's `cmd || echo ... >&2` swallow made "script
# missing" and "script ran clean" share an exit code (see
# checks-must-distinguish-unknown.md).
#
# The advice above is prose only — it can be read and ignored under time
# pressure, which is exactly what happened. This script is the same grep,
# made mechanical: it runs automatically at pre-commit (once installed —
# see the bottom of this header) whenever the staged diff DELETES a file
# under one of the guarded paths, instead of depending on someone
# remembering to run it by hand.
#
# WHY THIS IS THE RIGHT LAYER (not a PreToolUse:Bash hook on `rm`/`git rm`):
# a bare `rm path/to/script.sh` or `git rm` carries no evidence a
# consumer-grep was ever run — there is nothing in that single command for a
# PreToolUse hook to inspect or require. The actual signal that a deletion is
# about to happen and is final is the STAGED DIFF at commit time, which is
# exactly what git already computes for us. A PreToolUse hook could still
# nag on every `rm`/`git rm` call, but it would fire on ordinary file
# clean-up too (removing a stray *.log, an old worktree, a scratch file) and
# have no cheap way to tell "this rm is part of a considered deletion of a
# shared script" from "this rm is routine housekeeping" — so it was not
# built. Pre-commit, by contrast, only fires when a commit actually removes
# a tracked file under a guarded path, which is the precise moment #773 went
# wrong.
#
# WHAT THIS CANNOT SEE: a consumer that lives on a machine other than this
# one, or a project not yet cloned under the search root. That is the same
# limitation the manual `grep -rl <basename> ~/docs_gh/` advice already has —
# this script does not claim a stronger guarantee, only removes the "someone
# has to remember to run it" failure mode.
#
# Guarded paths (mirrors AGENTS.md + llm#1067's own scope):
#   .claude/scripts/**  .claude/hooks/**  .claude/templates/**  bin/**
#
# Usage:
#   pruned_script_consumer_check.sh              # scans staged deletions
#   pruned_script_consumer_check.sh --selftest
#
# Env overrides (testability / scope control — never needed in normal use):
#   CONSUMER_CHECK_ROOT  — root to grep for surviving consumers
#                          (default: $HOME/docs_gh)
#   CONSUMER_CHECK_REPO  — repo whose staged diff is inspected
#                          (default: `git rev-parse --show-toplevel`)
#
# Exit codes (checks-must-distinguish-unknown):
#   0  PASS         — no guarded deletions staged, or none referenced
#                      elsewhere under CONSUMER_CHECK_ROOT
#   1  FAIL         — a deleted file's basename is still referenced by a
#                      file that survives this commit (a real consumer)
#   2  usage error  — bad flags
#   3  INDETERMINATE — could not search (CONSUMER_CHECK_ROOT missing, git
#                      itself failed). NOT a pass — see
#                      pruned_script_consumer_precommit.sh for how the
#                      pre-commit wrapper treats this (warn, does not block).
#
# NOT auto-installed. See pruned_script_consumer_install.sh (mirrors
# indeterminate_hook_install.sh's install pattern) to wire this into
# .git/hooks/pre-commit.
#
# llm#1067

set -uo pipefail

SELFTEST=0
case "${1:-}" in
    (--selftest) SELFTEST=1 ;;
    (-h|--help)
        echo "Usage: $(basename "$0") [--selftest]" >&2
        exit 2 ;;
    ("") : ;;
    (*)
        echo "Usage: $(basename "$0") [--selftest]" >&2
        exit 2 ;;
esac

# Guarded path prefixes, relative to the repo root whose staged diff we scan.
GUARDED_PREFIXES=(".claude/scripts/" ".claude/hooks/" ".claude/templates/" "bin/")

# Directories to skip when grepping for surviving consumers — noise, not
# signal. `.git` avoids matching a deletion's own (still-packed) blob text
# via any tool that shells into git internals; `worktrees` avoids treating
# ephemeral scratch checkouts of THIS SAME repo as separate "projects" (the
# real 2026 incident was a genuinely separate project, not a stale worktree).
EXCLUDE_DIRS=(".git" "worktrees" "node_modules" "_targets" "_freeze" ".quarto" "renv")

_is_guarded_path() {
    local p="$1" prefix
    for prefix in "${GUARDED_PREFIXES[@]}"; do
        case "$p" in
            ("$prefix"*) return 0 ;;
        esac
    done
    return 1
}

_grep_exclude_args() {
    local d
    for d in "${EXCLUDE_DIRS[@]}"; do
        printf ' --exclude-dir=%s' "$d"
    done
}

# _run <repo> <root>  — the actual check, used by both main and selftest so
# the exact same logic is exercised both ways.
# Prints findings (one per surviving consumer) to stdout; returns:
#   0 = pass (no guarded deletions, or none referenced)
#   1 = fail (>=1 surviving consumer found)
#   3 = indeterminate (root or repo unusable)
_run() {
    local repo="$1" root="$2"
    local deleted
    if [ ! -d "$repo" ] || ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
        echo "INDETERMINATE: '$repo' is not a git repository — cannot inspect the staged diff." >&2
        return 3
    fi
    if [ ! -d "$root" ]; then
        echo "INDETERMINATE: consumer-search root '$root' does not exist — cannot verify absence of consumers." >&2
        return 3
    fi

    # -M detects clean renames (type R, not D) so a `git mv` is never treated
    # as a deletion. --diff-filter=D only.
    deleted="$(git -C "$repo" diff --cached --no-ext-diff -M --name-status --diff-filter=D 2>/dev/null | cut -f2-)"
    if [ -z "$deleted" ]; then
        echo "pruned-script-consumer-check: no staged deletions."
        return 0
    fi

    local any_guarded=0 any_fail=0
    local excl_args
    excl_args="$(_grep_exclude_args)"

    while IFS= read -r relpath; do
        [ -z "$relpath" ] && continue
        _is_guarded_path "$relpath" || continue
        any_guarded=1
        local base
        base="$(basename "$relpath")"

        # grep -I: skip binary files. -r: recurse. -l: names only.
        # shellcheck disable=SC2086
        local hits
        hits="$(grep -rlI $excl_args -- "$base" "$root" 2>/dev/null)" || hits=""

        if [ -n "$hits" ]; then
            any_fail=1
            echo "FAIL [$relpath]: basename '$base' is still referenced under $root by:"
            printf '    %s\n' "$hits"
        fi
    done <<EOF
$deleted
EOF

    if [ "$any_guarded" -eq 0 ]; then
        echo "pruned-script-consumer-check: staged deletions present, none under a guarded path."
        return 0
    fi
    if [ "$any_fail" -eq 1 ]; then
        return 1
    fi
    echo "pruned-script-consumer-check: guarded deletion(s) staged; no surviving consumers found under $root."
    return 0
}

if [ "$SELFTEST" -eq 1 ]; then
    _pass=0; _fail=0
    _ok()  { _pass=$((_pass+1)); echo "  PASS: $1"; }
    _bad() { _fail=$((_fail+1)); echo "  FAIL: $1"; }
    echo "pruned_script_consumer_check.sh --selftest"

    _mk_repo() {
        local d="$1"
        mkdir -p "$d"
        git init -q "$d"
        git -C "$d" config user.email "test@example.com"
        git -C "$d" config user.name "Test"
    }

    # ── Test 1: a real surviving consumer in another project — FAIL ---------
    _repo1="$(mktemp -d)"; _root1="$(mktemp -d)"
    _mk_repo "$_repo1"
    mkdir -p "$_repo1/.claude/scripts"
    printf '#!/bin/bash\necho hi\n' > "$_repo1/.claude/scripts/target_script.sh"
    git -C "$_repo1" add -A
    git -C "$_repo1" commit -qm "add target_script.sh"
    rm "$_repo1/.claude/scripts/target_script.sh"
    git -C "$_repo1" add -A   # stages the deletion

    mkdir -p "$_root1/other_project"
    echo '"$HOME/.claude/scripts/target_script.sh" . || echo "advisory" >&2' \
        > "$_root1/other_project/post-render.sh"

    _out1="$(_run "$_repo1" "$_root1")"; _rc1=$?
    if [ "$_rc1" -eq 1 ] && printf '%s' "$_out1" | grep -q "post-render.sh"; then
        _ok "surviving consumer in another project → FAIL, names the consumer file"
    else
        _bad "expected rc=1 naming post-render.sh, got rc=$_rc1 out='$_out1'"
    fi
    rm -rf "$_repo1" "$_root1"

    # ── Test 2: genuinely unused deletion — PASS -----------------------------
    _repo2="$(mktemp -d)"; _root2="$(mktemp -d)"
    _mk_repo "$_repo2"
    mkdir -p "$_repo2/.claude/scripts"
    printf '#!/bin/bash\necho hi\n' > "$_repo2/.claude/scripts/truly_unused.sh"
    git -C "$_repo2" add -A
    git -C "$_repo2" commit -qm "add truly_unused.sh"
    rm "$_repo2/.claude/scripts/truly_unused.sh"
    git -C "$_repo2" add -A

    mkdir -p "$_root2/other_project"
    echo 'nothing relevant here' > "$_root2/other_project/notes.md"

    _out2="$(_run "$_repo2" "$_root2")"; _rc2=$?
    if [ "$_rc2" -eq 0 ]; then
        _ok "genuinely unused deletion → PASS"
    else
        _bad "expected rc=0, got rc=$_rc2 out='$_out2'"
    fi
    rm -rf "$_repo2" "$_root2"

    # ── Test 3: no deletions staged at all — PASS, fast, no false alarm -----
    _repo3="$(mktemp -d)"; _root3="$(mktemp -d)"
    _mk_repo "$_repo3"
    mkdir -p "$_repo3/.claude/scripts"
    printf '#!/bin/bash\n' > "$_repo3/.claude/scripts/kept.sh"
    git -C "$_repo3" add -A
    git -C "$_repo3" commit -qm "add kept.sh"
    echo "# a harmless edit" >> "$_repo3/.claude/scripts/kept.sh"
    git -C "$_repo3" add -A   # an EDIT, not a deletion

    _out3="$(_run "$_repo3" "$_root3")"; _rc3=$?
    if [ "$_rc3" -eq 0 ] && printf '%s' "$_out3" | grep -q "no staged deletions"; then
        _ok "no staged deletions → PASS, distinct message"
    else
        _bad "expected rc=0 'no staged deletions', got rc=$_rc3 out='$_out3'"
    fi
    rm -rf "$_repo3" "$_root3"

    # ── Test 4: deletion outside guarded paths — PASS, distinct message -----
    _repo4="$(mktemp -d)"; _root4="$(mktemp -d)"
    _mk_repo "$_repo4"
    printf 'x <- 1\n' > "$_repo4/analysis.R"
    git -C "$_repo4" add -A
    git -C "$_repo4" commit -qm "add analysis.R"
    rm "$_repo4/analysis.R"
    git -C "$_repo4" add -A

    _out4="$(_run "$_repo4" "$_root4")"; _rc4=$?
    if [ "$_rc4" -eq 0 ] && printf '%s' "$_out4" | grep -q "none under a guarded path"; then
        _ok "deletion outside guarded paths → PASS, distinct message (not confused with Test 3)"
    else
        _bad "expected rc=0 'none under a guarded path', got rc=$_rc4 out='$_out4'"
    fi
    rm -rf "$_repo4" "$_root4"

    # ── Test 5: co-deleted consumer (same commit) is NOT a false positive ---
    # The only historical reference to target_script.sh lived in a file that
    # is ALSO deleted in this commit. Because the check greps the live
    # filesystem (not git history), that reference is already gone from
    # disk by the time pre-commit runs — this proves it stays gone, i.e.
    # this check scans working-tree state, not stale history.
    _repo5="$(mktemp -d)"; _root5="$(mktemp -d)"
    _mk_repo "$_repo5"
    mkdir -p "$_repo5/.claude/scripts"
    printf '#!/bin/bash\n' > "$_repo5/.claude/scripts/target_script.sh"
    printf '#!/bin/bash\n"$HOME/.claude/scripts/target_script.sh" || true\n' \
        > "$_repo5/.claude/scripts/consumer_script.sh"
    git -C "$_repo5" add -A
    git -C "$_repo5" commit -qm "add both"
    rm "$_repo5/.claude/scripts/target_script.sh" "$_repo5/.claude/scripts/consumer_script.sh"
    git -C "$_repo5" add -A

    _out5="$(_run "$_repo5" "$_repo5")"; _rc5=$?   # root = repo itself (self-search)
    if [ "$_rc5" -eq 0 ]; then
        _ok "co-deleted consumer (same commit) → PASS, not a false positive"
    else
        _bad "expected rc=0 (consumer removed too), got rc=$_rc5 out='$_out5'"
    fi
    rm -rf "$_repo5" "$_root5"

    # ── Test 6: missing search root — INDETERMINATE, never silent pass ------
    _repo6="$(mktemp -d)"
    _mk_repo "$_repo6"
    mkdir -p "$_repo6/bin"
    printf '#!/bin/bash\n' > "$_repo6/bin/gone.sh"
    git -C "$_repo6" add -A
    git -C "$_repo6" commit -qm "add gone.sh"
    rm "$_repo6/bin/gone.sh"
    git -C "$_repo6" add -A

    _out6="$(_run "$_repo6" "/nonexistent/path/$$/does-not-exist" 2>&1)"; _rc6=$?
    if [ "$_rc6" -eq 3 ] && printf '%s' "$_out6" | grep -q "INDETERMINATE"; then
        _ok "missing search root → INDETERMINATE (exit 3), never a silent pass"
    else
        _bad "expected rc=3 INDETERMINATE, got rc=$_rc6 out='$_out6'"
    fi
    rm -rf "$_repo6"

    # ── Test 7: not a git repo — INDETERMINATE -------------------------------
    _notrepo="$(mktemp -d)"
    _out7="$(_run "$_notrepo" "$_notrepo" 2>&1)"; _rc7=$?
    if [ "$_rc7" -eq 3 ] && printf '%s' "$_out7" | grep -q "INDETERMINATE"; then
        _ok "not a git repository → INDETERMINATE (exit 3)"
    else
        _bad "expected rc=3 INDETERMINATE, got rc=$_rc7 out='$_out7'"
    fi
    rm -rf "$_notrepo"

    echo ""
    echo "selftest: $((_pass+_fail)) tests — PASS=$_pass FAIL=$_fail"
    [ "$_fail" -eq 0 ] && exit 0 || exit 1
fi

# ── Main ─────────────────────────────────────────────────────────────────────
_REPO="${CONSUMER_CHECK_REPO:-$(git rev-parse --show-toplevel 2>/dev/null)}"
_ROOT="${CONSUMER_CHECK_ROOT:-$HOME/docs_gh}"

if [ -z "$_REPO" ]; then
    echo "INDETERMINATE: not inside a git repository (and CONSUMER_CHECK_REPO not set)." >&2
    exit 3
fi

_run "$_REPO" "$_ROOT"
exit $?
