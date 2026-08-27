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
#   3. A FUNCTION whose last command discards both stderr and status, so its
#      empty stdout means both "no result" and "could not run":
#          _get_pr_commits() { "$GH" pr view ... 2>/dev/null || echo ""; }
#      This is the llm#1012 shape. Patterns 1 and 2 both require the swallow
#      and its misreading in one variable's scan; here they were one function
#      call apart, and this checker reported findings=0 on that exact file.
#      (llm#1030.)
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

    # Pattern 3 — a FUNCTION whose result conflates error with empty (llm#1030).
    #
    # Patterns 1 and 2 both require the swallow and its misreading to sit in
    # one scan of one variable name. llm#1012 put them one function call apart:
    #
    #     _get_pr_commits() {
    #       "$GH" pr view ... 2>/dev/null || echo ""     # the swallow
    #     }
    #     commit_shas=$(_get_pr_commits "$pr" "$repo")
    #     if [ -z "$commit_shas" ]; then                 # the misreading
    #       echo "merge-gate: PASS (no commits found — fail-open)"
    #
    # Neither half matches alone, so this checker reported findings=0 on the
    # exact file it names first in its own header. Wrapping a swallow in a
    # helper — ordinary, good factoring — made the code invisible to it.
    #
    # What is flagged: a function whose LAST effective command swallows both
    # stderr and status. Such a function is structurally incapable of telling
    # its caller "I could not answer" — its stdout is empty either way — so
    # every caller that tests it for emptiness inherits the defect, wherever
    # they live. Flagging the function is both earlier and cheaper than
    # chasing its call sites.
    #
    # Deliberately NOT flagged: a swallow in the middle of a function that
    # goes on to branch, and a function that captures the status (`|| rc=$?`).
    # Those are the correct forms, and both appear in the fixes for llm#1012
    # and llm#1019.
    # Only functions whose STDOUT IS CONSUMED can carry this defect. A
    # fire-and-forget side-effecting function -- worktree_gc.sh's
    # write_gc_event(), whose last line is a DuckDB write ending
    # `2>/dev/null || true` -- has the same shape and no defect: nobody reads
    # its output, and a failed telemetry write must not crash the sweep. That
    # was the first false positive this pattern produced, and the checker's
    # own selftest already accepts "fire-and-forget with no emptiness test" as
    # good. So: emit `line<TAB>name` from awk, then keep only names that
    # appear inside a command substitution somewhere in the same file.
    local fn_hits
    fn_hits="$(awk '
        # A heredoc body is DATA, not code in this file. Without this, the
        # selftest fixtures below -- which deliberately contain the defect --
        # are reported as defects in this script itself. Any scanner that
        # cannot tell its own fixtures from its own code will accumulate
        # exactly one self-referential finding per test it adds.
        !inhd && /<<[-]?[\x27"]?[A-Za-z_][A-Za-z0-9_]*[\x27"]?[[:space:]]*$/ {
            hd = $0
            sub(/^.*<<[-]?[\x27"]?/, "", hd)
            sub(/[\x27"]?[[:space:]]*$/, "", hd)
            inhd = 1; next
        }
        inhd { if ($0 == hd) inhd = 0; next }

        /^[[:space:]]*(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)[[:space:]]*\{/ {
            infn = 1
            fname = $0
            sub(/^[[:space:]]*(function[[:space:]]+)?/, "", fname)
            sub(/[[:space:]]*\(\).*$/, "", fname)
            last = ""; lastline = 0; next
        }
        infn && /^\}/ {
            if (last ~ /2>\/dev\/null/ && (last ~ /\|\|[[:space:]]*true[[:space:]]*$/ || last ~ /\|\|[[:space:]]*echo[[:space:]]+""[[:space:]]*$/)) {
                print lastline "\t" fname
            }
            infn = 0; next
        }
        infn {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            if (line == "" || line ~ /^#/) next
            # A status capture means the function CAN report failure.
            if (line ~ /\|\|[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=\$\?/) { last = ""; lastline = 0; next }
            if (line ~ /^return[[:space:]]/) { last = ""; lastline = 0; next }
            last = line; lastline = NR
        }
    ' "$f" 2>/dev/null || true)"

    if [ -n "$fn_hits" ]; then
        while IFS="$(printf '\t')" read -r hl hname; do
            [ -n "$hl" ] || continue
            [ -n "${hname:-}" ] || continue
            # Consumed anywhere as $(name ...) or `name ...`?
            grep -qE '(\$\(|`)[[:space:]]*'"$hname"'([[:space:]]|\)|`)' "$f" 2>/dev/null || continue
            _is_allowlisted "$rel" && continue
            echo "$rel:$hl: [swallowed-status-fn] ${hname}()'s last command discards stderr and exit status, and its output IS captured by a caller. Empty stdout therefore means BOTH \"no result\" and \"could not run\" (llm#1012)."
        done <<< "$fn_hits"
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
    # A fixture that was never written produces no findings, and "no findings"
    # is this suite's PASS condition for every accepts-* case. So an absent
    # fixture reads as a pass -- the exact defect this script exists to catch,
    # in this script's own selftest. It happened: the llm#1030 cases were
    # added below the `rm -rf "$tmp"` line and two of them "passed" against
    # files that did not exist. Assert existence and non-emptiness before
    # drawing any conclusion from a scan.
    _fixture(){
        if [ ! -s "$1" ]; then
            bad "fixture $(basename "$1") was not written -- cannot conclude anything from scanning it"
            return 1
        fi
        return 0
    }
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

    # ── llm#1030 — the swallow and its misreading one function call apart ──
    # This is verbatim the llm#1012 shape. Before pattern 3 the checker
    # reported findings=0 on the real file.
    cat > "$tmp/bad3.sh" <<'EOS'
#!/usr/bin/env bash
_get_pr_commits() {
  local pr_num="$1" repo="$2"
  "$GH" pr view "$pr_num" --repo "$repo" --json commits --jq '.commits[].oid' 2>/dev/null || echo ""
}
main() {
  commit_shas=$(_get_pr_commits "$pr_num" "$repo")
  if [ -z "$commit_shas" ]; then
    echo "merge-gate: PASS (no commits found — fail-open)"
    exit 0
  fi
}
EOS
    if _fixture "$tmp/bad3.sh" && scan_file "$tmp/bad3.sh" | grep -q 'swallowed-status-fn'; then
        ok "flags a consumed function whose last command swallows status (llm#1012/llm#1030)"
    else
        bad "missed the cross-function swallow (llm#1030)"
    fi

    # The names matter: a finding that cannot say WHICH function is a finding
    # the reader has to re-derive.
    if _fixture "$tmp/bad3.sh" && scan_file "$tmp/bad3.sh" | grep -q '_get_pr_commits()'; then
        ok "names the offending function"
    else
        bad "finding does not name the function"
    fi

    # Fire-and-forget — same shape, no defect, must NOT be flagged. This was
    # the first false positive pattern 3 produced (worktree_gc.sh's
    # write_gc_event, a DuckDB telemetry write nobody reads).
    cat > "$tmp/good5.sh" <<'EOS'
#!/usr/bin/env bash
write_gc_event() {
  duckdb "$DB" -c "INSERT INTO events VALUES ('$1');" 2>/dev/null || true
}
write_gc_event "something"
EOS
    if _fixture "$tmp/good5.sh" && [ -z "$(scan_file "$tmp/good5.sh")" ]; then
        ok "accepts a fire-and-forget function whose output nobody captures"
    else
        bad "false positive on fire-and-forget (the write_gc_event shape)"
    fi

    # The corrected form from llm#1012 — status captured, caller can branch.
    cat > "$tmp/good6.sh" <<'EOS'
#!/usr/bin/env bash
_get_pr_commits() {
  local out rc=0
  out=$("$GH" pr view "$1" --json commits --jq '.commits[].oid' 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s' "gh failed (rc=$rc)"
    return 3
  fi
  printf '%s' "$out"
  return 0
}
rc=0
shas=$(_get_pr_commits 99) || rc=$?
EOS
    if _fixture "$tmp/good6.sh" && [ -z "$(scan_file "$tmp/good6.sh")" ]; then
        ok "accepts the rc-capturing function form (the llm#1012 fix)"
    else
        bad "false positive on the corrected function form"
    fi

    # Cleanup moved here from above: the llm#1030 cases below it were
    # writing fixtures into a directory that had already been removed. Each
    # `cat >` failed, scan_file saw nothing, and "no output" read as PASS --
    # this checker's own defect, in this checker's own selftest. The
    # _fixture helper below is the guard against it recurring.

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
