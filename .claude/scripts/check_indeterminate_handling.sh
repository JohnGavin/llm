#!/usr/bin/env bash
# check_indeterminate_handling.sh — flag the swallowed-error signature that lets
# "I could not answer" masquerade as "the answer is no".
#
# Enforces the checks-must-distinguish-unknown rule. That rule is prose, and
# prose did not stop six instances in one week (llm#1012 #746 #913 #1013 #1017
# #1019). This is the mechanical half.
#
# WHAT IT FLAGS
#
#   1. A command substitution that discards BOTH stderr and exit status,
#      whose result is later tested for emptiness:
#          x=$(cmd 2>/dev/null || true)
#          [ -z "$x" ] && return 0            # ← "not found" OR "could not ask"
#      This is the llm#1019 shape: a `gh` 401 became "no merged PR exists" and
#      the GC retained ~5 GB of already-merged worktrees indefinitely.
#
#   2. An unguarded command substitution containing a pipeline, in a file that
#      sets `set -e`/`set -o pipefail`. A grep that matches nothing exits 1,
#      fails the pipeline, and aborts the script mid-run — often before it
#      prints its own summary, so a crash is indistinguishable from a finding.
#      (llm#695; llmtelemetry#353 had the same bug inside a QA gate.)
#
# It does NOT flag `cmd 2>/dev/null || true` on its own — that is legitimate
# when the caller genuinely does not care. The defect is discarding the status
# and *then* interpreting emptiness as a negative answer.
#
# Usage:
#   check_indeterminate_handling.sh [path ...]     # default: .claude/scripts .claude/hooks bin
#   check_indeterminate_handling.sh --selftest
#
# Exit: 0 clean · 1 findings · 2 could not run
#       (note the exit codes obey the rule this script enforces)
#
# llm#1022

set -uo pipefail

SELFTEST=0
WRITE_BASELINE=0
USE_BASELINE=1
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALLOWLIST="${INDETERMINATE_ALLOWLIST:-$_SCRIPT_DIR/.indeterminate-allowlist}"
BASELINE="${INDETERMINATE_BASELINE:-$_SCRIPT_DIR/.indeterminate-baseline}"
PATHS=()

while [ $# -gt 0 ]; do
    case "$1" in
        (--selftest)       SELFTEST=1; shift ;;
        (--write-baseline) WRITE_BASELINE=1; shift ;;
        (--all)            USE_BASELINE=0; shift ;;
        (-h|--help)
            echo "Usage: $(basename "$0") [--selftest|--write-baseline|--all] [path ...]" >&2
            echo "  default          report only findings NOT in the baseline; exit 1 if any" >&2
            echo "  --all            report every finding, ignoring the baseline" >&2
            echo "  --write-baseline accept all current findings as known (shrink it over time)" >&2
            exit 2 ;;
        (*)                PATHS+=("$1"); shift ;;
    esac
done

_is_allowlisted() {
    [ -f "$ALLOWLIST" ] || return 1
    grep -v '^\s*#' "$ALLOWLIST" 2>/dev/null | grep -v '^\s*$' | grep -qxF "$1"
}

# Scan one file. Prints one finding per line; returns count via stdout only.
scan_file() {
    local f="$1"
    [ -r "$f" ] || return 0
    local rel="$f"

    # Pattern 1 — swallow-then-emptiness-test.
    # Collect variables assigned from a substitution that discards status.
    local vars
    vars="$(grep -nE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=\$\(.*(2>/dev/null|2>&-).*(\|\|[[:space:]]*true|\|\|[[:space:]]*echo[[:space:]]+"")' "$f" 2>/dev/null \
            | sed -E 's/^([0-9]+):[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=.*/\1 \2/')"

    if [ -n "$vars" ]; then
        while IFS=' ' read -r lineno var; do
            [ -n "${var:-}" ] || continue
            # Is that variable later tested for emptiness?
            if grep -qE "\[[[:space:]]+-z[[:space:]]+\"?\\\$\{?$var" "$f" 2>/dev/null; then
                _is_allowlisted "$rel" && continue
                echo "$rel:$lineno: [swallowed-status] \$$var is assigned from a substitution that discards stderr and exit status, then tested with -z. An error and a negative result are indistinguishable here."
            fi
        done <<< "$vars"
    fi

    # Pattern 2 — unguarded pipeline substitution under set -e/pipefail.
    if grep -qE '^[[:space:]]*set[[:space:]]+-[a-z]*e|set[[:space:]]+-o[[:space:]]+pipefail' "$f" 2>/dev/null; then
        local hits
        hits="$(grep -nE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=\$\((grep|rg|awk|sed)[^)]*\|' "$f" 2>/dev/null \
                | grep -vE '\|\|[[:space:]]*(true|echo)' || true)"
        if [ -n "$hits" ]; then
            while IFS= read -r h; do
                [ -n "$h" ] || continue
                _is_allowlisted "$rel" && continue
                echo "$rel:${h%%:*}: [pipefail-abort] pipeline in a command substitution with no '|| true', under set -e/pipefail. A non-matching grep aborts the script mid-run — a crash that looks like a finding."
            done <<< "$hits"
        fi
    fi
}

selftest() {
    local tmp pass=0 fail=0
    tmp="$(mktemp -d)"
    ok(){ pass=$((pass+1)); echo "  PASS: $1"; }
    bad(){ fail=$((fail+1)); echo "  FAIL: $1"; }
    echo "check_indeterminate_handling.sh --selftest"

    # The llm#1019 shape — must be flagged.
    cat > "$tmp/bad1.sh" <<'EOS'
#!/usr/bin/env bash
_pr_json=$(gh pr list --json number 2>/dev/null || true)
[ -z "$_pr_json" ] && return 0
EOS
    if scan_file "$tmp/bad1.sh" | grep -q 'swallowed-status'; then
        ok "flags the swallow-then-emptiness shape (llm#1019)"
    else
        bad "missed the swallow-then-emptiness shape"
    fi

    # The llm#695 shape — must be flagged.
    cat > "$tmp/bad2.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
LINE=$(grep -n "thing" "$F" | head -1 | cut -d: -f1)
EOS
    if scan_file "$tmp/bad2.sh" | grep -q 'pipefail-abort'; then
        ok "flags the unguarded pipeline substitution (llm#695)"
    else
        bad "missed the unguarded pipeline substitution"
    fi

    # Guarded version — must NOT be flagged.
    cat > "$tmp/good1.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
LINE=$(grep -n "thing" "$F" | head -1 | cut -d: -f1 || true)
EOS
    if [ -z "$(scan_file "$tmp/good1.sh")" ]; then
        ok "accepts the guarded pipeline substitution"
    else
        bad "false positive on the guarded form"
    fi

    # Status captured and branched on — must NOT be flagged.
    cat > "$tmp/good2.sh" <<'EOS'
#!/usr/bin/env bash
out=$(gh pr list --json number 2>"$err"); rc=$?
if [ "$rc" -ne 0 ]; then echo "INDETERMINATE"; return 2; fi
[ -z "$out" ] && return 0
EOS
    if [ -z "$(scan_file "$tmp/good2.sh")" ]; then
        ok "accepts the required rc-capturing pattern"
    else
        bad "false positive on the correct pattern"
    fi

    # Discarding status WITHOUT an emptiness test — legitimate, must NOT flag.
    cat > "$tmp/good3.sh" <<'EOS'
#!/usr/bin/env bash
_best_effort=$(some_optional_thing 2>/dev/null || true)
echo "carrying on regardless"
EOS
    if [ -z "$(scan_file "$tmp/good3.sh")" ]; then
        ok "accepts fire-and-forget with no emptiness test"
    else
        bad "false positive on legitimate fire-and-forget"
    fi

    rm -rf "$tmp"
    echo "  $pass passed, $fail failed"
    [ "$fail" -eq 0 ]
}

[ "$SELFTEST" -eq 1 ] && { selftest; exit $?; }

# INDETERMINATE_ROOT overrides the scan/baseline root. Required, not cosmetic:
# ~/.claude/scripts is a SYMLINK into the main checkout, so deriving ROOT from
# this script's own location always resolves to the main checkout — even when
# invoked from a worktree's pre-commit hook. The gate then scanned main's files,
# found them baselined, and passed every commit made from a worktree regardless
# of its content. A check looking in the wrong place and reporting clean
# (llm#1028).
ROOT="${INDETERMINATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
if [ "${#PATHS[@]}" -eq 0 ]; then
    PATHS=("$ROOT/.claude/scripts" "$ROOT/.claude/hooks" "$ROOT/bin")
fi

# Baseline entries are stored REPO-RELATIVE. Absolute paths would differ between
# the main checkout and every worktree, so a committed baseline built in one
# would match nothing in the other — the portable-build-artifacts trap.
_rel() { printf '%s' "${1#"$ROOT"/}"; }

# Signature ignores the line number: a finding must not reappear as "new"
# because unrelated lines were inserted above it. file + finding-type is stable
# under edits elsewhere in the file, and precise enough that a genuinely new
# instance of the same type in the same file still surfaces once.
_sig() { printf '%s\t%s' "$(_rel "$1")" "$2"; }

collected=""
scanned=0
for p in "${PATHS[@]}"; do
    [ -e "$p" ] || continue
    while IFS= read -r f; do
        scanned=$((scanned + 1))
        out="$(scan_file "$f")"
        [ -n "$out" ] && collected="${collected}${out}"$'\n'
    done < <(find "$p" -type f -name '*.sh' 2>/dev/null)
done

if [ "$WRITE_BASELINE" -eq 1 ]; then
    {
        echo "# check_indeterminate_handling.sh baseline"
        echo "# Pre-existing findings, accepted so the checker can block NEW ones."
        echo "# Entries are <repo-relative-path><TAB><finding-type>. Line numbers are"
        echo "# deliberately excluded so edits elsewhere in a file do not resurrect an"
        echo "# entry as 'new'."
        echo "#"
        echo "# This file should SHRINK. Deleting a line here means that file must be"
        echo "# clean of that finding type. Never add to it by hand — fix the code, or"
        echo "# regenerate deliberately with --write-baseline and say why in the commit."
        printf '%s\n' "$collected" | grep -c . >/dev/null 2>&1 || true
        printf '%s\n' "$collected" | grep . | while IFS= read -r line; do
            _f="${line%%:*}"
            _type="$(printf '%s' "$line" | sed -nE 's/.*\[([a-z-]+)\].*/\1/p')"
            [ -n "$_type" ] && _sig "$_f" "$_type" && printf '\n'
        done | sort -u
    } > "$BASELINE"
    echo "indeterminate-handling: baseline written to $(_rel "$BASELINE") ($(grep -vc '^#' "$BASELINE" 2>/dev/null || echo 0) entries)"
    exit 0
fi

new_findings=0
total=0
while IFS= read -r line; do
    [ -n "$line" ] || continue
    total=$((total + 1))
    _f="${line%%:*}"
    _type="$(printf '%s' "$line" | sed -nE 's/.*\[([a-z-]+)\].*/\1/p')"
    if [ "$USE_BASELINE" -eq 1 ] && [ -f "$BASELINE" ] \
       && grep -qxF "$(_sig "$_f" "$_type")" "$BASELINE" 2>/dev/null; then
        continue   # known, accepted
    fi
    printf '%s\n' "$line"
    new_findings=$((new_findings + 1))
done <<< "$collected"

if [ "$USE_BASELINE" -eq 1 ] && [ -f "$BASELINE" ]; then
    baselined=$(( total - new_findings ))
    echo "indeterminate-handling: scanned=$scanned new=$new_findings baselined=$baselined"
else
    echo "indeterminate-handling: scanned=$scanned findings=$total (no baseline)"
fi
[ "$new_findings" -eq 0 ] || exit 1
exit 0
