#!/usr/bin/env bash
# secret_exposure_scan.sh — aggressive, auto-triggered secret-exposure scanner.
#
# Why this exists (not a rule, not a memory note): three incidents in one
# week hit the same failure shape — a whole-environment or whole-file
# capture routed somewhere it should not go, plus plaintext credentials at
# rest with wrong permissions:
#   1. `gh issue comment --body "...printenv..."` spliced the whole shell
#      environment into a PUBLIC GitHub comment (14 live credentials).
#   2. `default.sh` did `export -p | grep -v <denylist> > nix_env.sh`
#      (world-readable, mode 644) — a DENYLIST filter fails open; it only
#      knows what to hide, not what is safe to keep (11 live credentials).
#   3. A migration "commented out" secrets instead of deleting them —
#      still fully readable in ~/.zshenv.
# A rule/memory note is advisory and gets ignored under pressure. This
# script is deterministic code, run on a schedule and at session start,
# that TAKES ACTION on the safe subset of findings. Aggressive detection,
# conservative mutation — see the "--fix actions" table below.
#
# Usage:
#   secret_exposure_scan.sh [--scan|--fix|--selftest] [--json] [--quiet] [--fast]
#
#   --scan      (default) detect and report. Exit 0 clean, 1 findings.
#   --fix       detect, then apply the SAFE remediations only (see table).
#               Exit 0 if all remaining findings were remediated, 1 if
#               manual action is still required.
#   --selftest  run the fixture-based acceptance suite. Prints
#               "selftest: N/N PASS" and exits non-zero on any failure.
#   --json      emit findings as JSON instead of text (scan/fix only).
#   --quiet     suppress the "clean" banner on a 0-finding scan.
#   --fast      dotfile/config set ONLY — skips the repo source-tree scan.
#               Use this at session start so the hook stays fast; the
#               full repo scan (default, no --fast) is for the scheduled
#               launchd run. Session-init has NOT been wired to call this
#               yet — wiring is a separate change; this flag exists so
#               that wiring only needs to add one call.
#
# Detectors (full detail + the allowlist-vs-denylist rule: see
# .claude/rules/secret-exposure-scanning.md):
#   1. whole-environment capture in *.sh/*.R/*.py/*.plist source, routed to
#      a file/pipe. Report only — never auto-rewrite source.
#   2. plaintext credential at rest: a literal credential-shaped value, OR
#      a KEY|TOKEN|SECRET|PASSWORD|PASSWD|PAT|CREDENTIAL-named variable
#      assigned a non-$-prefixed literal. Report only — deleting user data
#      is not a safe automatic action; the report prints the exact removal
#      command.
#   3. bad permissions on a Detector-2-flagged file (not 600/400).
#      `--fix` DOES `chmod 600` this automatically — reversible, no data
#      change.
#   4. a Detector-2-shaped assignment sitting on a COMMENT line —
#      "commented out" is not "removed". Report only.
#
# CRITICAL correctness requirement: this scanner must NEVER print a
# credential value, in --scan, --fix, --json, or the log file. Findings
# carry file, line number, variable NAME, and a detector id ONLY — never
# the matched line text. Verified by --selftest's sentinel-value check.
#
# Performance: pruned dirs are .git, node_modules, _targets, worktrees
# (covers .claude/worktrees), renv, library (covers renv/library). Target
# is ~3s on this repo; not yet verified against every possible repo size
# — if a future repo blows the budget, use --fast for the session-start
# path and reserve the full scan for the scheduled launchd job (which is
# exactly what --fast is for today).
#
# Log: ~/.claude/logs/secret_exposure_scan.log (one line per --fix action;
# ISO-8601 UTC timestamp, detector id, path, action taken). Log failures
# never abort the scan (best-effort, `|| true` throughout).
#
# Origin: three incidents, 2026-08 (see header above and the companion
# rule file for full incident detail).

set -uo pipefail
# Deliberately NOT `set -e`: a single non-matching grep (exit 1) or a
# failed chmod on one file must never abort the rest of the scan.

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

HOME_DIR="${HOME:-/Users/johngavin}"
LOG_DIR="${HOME_DIR}/.claude/logs"
LOG_FILE="${LOG_DIR}/secret_exposure_scan.log"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$REPO_ROOT" ]; then
    REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi

DEFAULT_DOTFILES=(
    "$HOME_DIR/.config"
    "$HOME_DIR/.claude/env"
    "$HOME_DIR/.zshenv"
    "$HOME_DIR/.zshrc"
    "$HOME_DIR/.bashrc"
    "$HOME_DIR/.bash_profile"
    "$HOME_DIR/.profile"
)

PRUNE_ARGS=(
    --exclude-dir=.git
    --exclude-dir=node_modules
    --exclude-dir=_targets
    --exclude-dir=worktrees
    --exclude-dir=renv
    --exclude-dir=library
)

# Literal credential-shaped value patterns. Overlap between generic and
# specific patterns (e.g. sk- vs sk-ant-) is deliberate belt-and-braces —
# both firing on the same line is a harmless duplicate finding, not a bug.
CRED_SHAPE_PATTERNS=(
    'ghp_[A-Za-z0-9]{30,}'
    'gho_[A-Za-z0-9]{30,}'
    'ghs_[A-Za-z0-9]{30,}'
    'github_pat_[A-Za-z0-9_]{20,}'
    'sk-ant-[A-Za-z0-9_-]{20,}'
    'sk-[A-Za-z0-9]{20,}'
    'hf_[A-Za-z0-9]{20,}'
    'xoxb-[A-Za-z0-9-]{10,}'
    'xoxp-[A-Za-z0-9-]{10,}'
    'AIza[A-Za-z0-9_-]{30,}'
    'AKIA[A-Z0-9]{16}'
    'glpat-[A-Za-z0-9_-]{20,}'
    '\-\-\-\-\-BEGIN[A-Z ]*PRIVATE KEY\-\-\-\-\-'
)

# Credential-shaped variable NAME (case-insensitive).
ASSIGN_NAME_RE='[A-Za-z_][A-Za-z0-9_]*(KEY|TOKEN|SECRET|PASSWORD|PASSWD|PAT|CREDENTIAL)[A-Za-z0-9_]*'
# A literal (non-$) value follows `=`. Matches with OR without a leading
# `#` comment marker — classified into detector 2 vs 4 after the match.
ASSIGN_RE="^[[:space:]]*#?[[:space:]]*(export[[:space:]]+)?${ASSIGN_NAME_RE}[[:space:]]*=[[:space:]]*[^\$[:space:]]"

# Whole-environment capture trigger tokens (detector 1).
ENV_CAPTURE_RE='(^|[;&|[:space:]])(export[[:space:]]+-p|declare[[:space:]]+-x|set[[:space:]]+-o[[:space:]]+posix|printenv|env)([[:space:]]|$)'

MODE="scan"
JSON=0
QUIET=0
FAST=0

FINDINGS_FILE=""

usage() {
    cat <<'EOF'
Usage: secret_exposure_scan.sh [--scan|--fix|--selftest] [--json] [--quiet] [--fast]
EOF
}

for arg in "$@"; do
    case "$arg" in
        --scan) MODE="scan" ;;
        --fix) MODE="fix" ;;
        --selftest) MODE="selftest" ;;
        --json) JSON=1 ;;
        --quiet) QUIET=1 ;;
        --fast) FAST=1 ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "secret_exposure_scan: unknown argument: $arg" >&2
            usage >&2
            exit 2
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# append_finding DETECTOR SEVERITY FILE LINE NAME NOTE
# NOTE must be a fixed, generic description — NEVER the matched line text
# or any captured value. This is the single choke point that guarantees
# the no-leaked-value contract; every caller MUST respect it.
append_finding() {
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "$FINDINGS_FILE"
}

log_action() {
    # log_action DETECTOR PATH ACTION — best-effort, never aborts the scan.
    {
        mkdir -p "$LOG_DIR" 2>/dev/null
        local ts
        ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
        printf '%s\tdet=%s\tpath=%s\taction=%s\n' "$ts" "$1" "$2" "$3" >> "$LOG_FILE"
    } 2>/dev/null || true
}

file_mode() {
    stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null || echo ""
}

# ---------------------------------------------------------------------------
# Detector 1 — whole-environment capture in source
# ---------------------------------------------------------------------------

scan_source_patterns() {
    [ -d "$REPO_ROOT" ] || return 0
    while IFS=: read -r file lnum rest; do
        [ -n "${file:-}" ] || continue
        # Candidate only if the line ALSO routes somewhere (pipe/redirect).
        if ! printf '%s' "$rest" | grep -qE '(\||>)'; then
            continue
        fi
        if printf '%s' "$rest" | grep -qE 'grep[^|]*-[a-zA-Z]*v[a-zA-Z]*'; then
            append_finding "1" "high" "$file" "$lnum" "denylist-capture" \
                "export/env dump filtered by a DENYLIST (grep -v...) -- fails open; use an explicit ALLOWLIST (grep -E \"^declare -x (ALLOWED_VAR1|ALLOWED_VAR2)=\") instead"
        elif printf '%s' "$rest" | grep -qE '\bgrep\b'; then
            : # positive grep present with no -v flag -- treated as an allowlist, not a finding
        else
            append_finding "1" "high" "$file" "$lnum" "unfiltered-capture" \
                "whole-environment/file capture routed to a file or pipe with no filter at all"
        fi
    done < <(grep -rnIE \
        --include='*.sh' --include='*.R' --include='*.py' --include='*.plist' \
        "${PRUNE_ARGS[@]}" \
        "$ENV_CAPTURE_RE" "$REPO_ROOT" 2>/dev/null)
}

# ---------------------------------------------------------------------------
# Detectors 2 + 4 — plaintext credentials at rest (live vs commented)
# ---------------------------------------------------------------------------

scan_at_rest() {
    local paths=()
    local p
    for p in "${DEFAULT_DOTFILES[@]}"; do
        [ -e "$p" ] && paths+=("$p")
    done
    if [ "$FAST" -eq 0 ] && [ -d "$REPO_ROOT" ]; then
        paths+=("$REPO_ROOT")
    fi
    [ "${#paths[@]}" -gt 0 ] || return 0

    # Literal credential shapes -- always detector 2 regardless of comment
    # status; an exposed value is exposed whether or not a `#` precedes it.
    local pat
    for pat in "${CRED_SHAPE_PATTERNS[@]}"; do
        while IFS=: read -r file lnum rest; do
            [ -n "${file:-}" ] || continue
            append_finding "2" "critical" "$file" "$lnum" "cred-shape" \
                "literal credential-shaped value detected (value redacted -- see rule doc for the pattern class)"
        done < <(grep -rnIE "${PRUNE_ARGS[@]}" -e "$pat" "${paths[@]}" 2>/dev/null)
    done

    # Credential-shaped NAME assigned a literal value -- comment line goes
    # to detector 4, everything else to detector 2.
    while IFS=: read -r file lnum rest; do
        [ -n "${file:-}" ] || continue
        if printf '%s' "$rest" | grep -qE '^[[:space:]]*#'; then
            append_finding "4" "high" "$file" "$lnum" "commented-credential-assignment" \
                "credential-shaped NAME with a literal value left on a comment line -- commenting out is NOT removal"
        else
            append_finding "2" "critical" "$file" "$lnum" "credential-assignment" \
                "credential-shaped variable NAME assigned a literal (non-\$) value"
        fi
    done < <(grep -rnIiE "${PRUNE_ARGS[@]}" -e "$ASSIGN_RE" "${paths[@]}" 2>/dev/null)
}

# ---------------------------------------------------------------------------
# Detector 3 — permissions on any Detector-2-flagged file
# ---------------------------------------------------------------------------

check_permissions() {
    local file mode
    while IFS= read -r file; do
        [ -n "$file" ] && [ -e "$file" ] || continue
        mode="$(file_mode "$file")"
        case "$mode" in
            600|400) continue ;;
            "") continue ;; # couldn't stat -- don't report a phantom finding
            *)
                append_finding "3" "high" "$file" "-" "bad-permissions" \
                    "mode $mode -- a file holding a live credential should be 600 or 400"
                ;;
        esac
    done < <(awk -F'\t' '$1=="2"{print $3}' "$FINDINGS_FILE" | sort -u)
}

# ---------------------------------------------------------------------------
# --fix — conservative remediation
# ---------------------------------------------------------------------------

apply_fixes() {
    while IFS=$'\t' read -r det sev file lnum name note; do
        case "$det" in
            3)
                if chmod 600 "$file" 2>/dev/null; then
                    log_action "3" "$file" "chmod 600 (was mode $note)"
                else
                    log_action "3" "$file" "chmod 600 FAILED"
                fi
                ;;
            2)
                log_action "2" "${file}:${lnum}" "NOT auto-fixed (deleting user data is unsafe) -- remove manually: sed -i '' '${lnum}d' '${file}'  # verify the line first"
                ;;
            4)
                log_action "4" "${file}:${lnum}" "NOT auto-fixed -- remove the commented-out assignment manually: sed -i '' '${lnum}d' '${file}'"
                ;;
            1)
                log_action "1" "${file}:${lnum}" "NOT auto-fixed -- source pattern requires human judgement (allowlist vs denylist); see rule doc"
                ;;
        esac
    done < "$FINDINGS_FILE"
}

remaining_after_fix() {
    local remaining
    remaining=$(awk -F'\t' '$1=="1"||$1=="2"||$1=="4"' "$FINDINGS_FILE" | wc -l | tr -d ' ')
    local file mode
    while IFS=$'\t' read -r det sev file lnum name note; do
        [ "$det" = "3" ] || continue
        mode="$(file_mode "$file")"
        case "$mode" in
            600|400) : ;;
            *) remaining=$((remaining + 1)) ;;
        esac
    done < "$FINDINGS_FILE"
    printf '%s' "$remaining"
}

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

print_report_json() {
    local first=1
    printf '{"findings":['
    while IFS=$'\t' read -r det sev file lnum name note; do
        [ "$first" -eq 1 ] || printf ','
        first=0
        printf '{"detector":"%s","severity":"%s","file":"%s","line":"%s","name":"%s","note":"%s"}' \
            "$(json_escape "$det")" "$(json_escape "$sev")" "$(json_escape "$file")" \
            "$(json_escape "$lnum")" "$(json_escape "$name")" "$(json_escape "$note")"
    done < "$FINDINGS_FILE"
    printf ']}\n'
}

print_report() {
    local total
    total=$(wc -l < "$FINDINGS_FILE" | tr -d ' ')

    if [ "$JSON" -eq 1 ]; then
        print_report_json
        return 0
    fi

    if [ "$total" -eq 0 ]; then
        [ "$QUIET" -eq 1 ] || echo "secret-exposure-scan: clean -- 0 findings"
        return 0
    fi

    echo "secret-exposure-scan: $total finding(s)"
    awk -F'\t' '{c[$1]++} END{for (d in c) print "  detector " d ": " c[d]}' "$FINDINGS_FILE" | sort
    echo "---"
    while IFS=$'\t' read -r det sev file lnum name note; do
        printf '  [%s] det=%s %s:%s %s -- %s\n' "$sev" "$det" "$file" "$lnum" "$name" "$note"
    done < "$FINDINGS_FILE"
}

# ---------------------------------------------------------------------------
# --selftest
# ---------------------------------------------------------------------------

run_selftest() {
    local tmp
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/secret_scan_selftest.XXXXXX")"

    mkdir -p "$tmp/repo" "$tmp/dotfiles"

    # 1: denylist-filtered export -p redirect -> FINDING (detector 1)
    cat > "$tmp/repo/bad_denylist.sh" <<'EOF'
#!/bin/bash
export -p | grep -vE "PASSWORD|TOKEN" > /tmp/dump.sh
EOF

    # 2: allowlist-filtered export -p redirect -> NO finding
    cat > "$tmp/repo/good_allowlist.sh" <<'EOF'
#!/bin/bash
export -p | grep -E "^declare -x (PATH|NIX_STORE)=" > /tmp/safe.sh
EOF

    # 3: literal ghp_-shaped credential -> FINDING (detector 2)
    cat > "$tmp/dotfiles/leaked_token.env" <<'EOF'
GITHUB_TOKEN=ghp_ABCDEFGHIJ0123456789abcdefghij0123456789
EOF

    # 4/5/6: mode-644 file holding a credential shape -> FINDING (detector 3);
    #        after --fix, mode is 600 and a re-scan is clean.
    cat > "$tmp/dotfiles/insecure_perms.env" <<'EOF'
HF_TOKEN=hf_ABCDEFGHIJ0123456789abcd
EOF
    chmod 644 "$tmp/dotfiles/insecure_perms.env"

    # 7/8: commented-out credential (detector 4) + indirection, not a
    #      literal (no finding).
    cat > "$tmp/dotfiles/commented.env" <<'EOF'
# API_KEY=sk-1234567890ABCDEFGHIJ
API_KEY=$SOME_VAR
EOF

    # 9: prose containing the word "password" -> NO finding (over-match check)
    cat > "$tmp/dotfiles/prose.txt" <<'EOF'
Remember to reset your password before the meeting.
EOF

    # 10/11/12: sentinel value must never surface in stdout, stderr, or the log
    local sentinel="SENTINEL_zQ9xxNeverPrintMe_7f3a"
    cat > "$tmp/dotfiles/sentinel.env" <<EOF
AWS_SECRET_ACCESS_KEY=${sentinel}
EOF

    REPO_ROOT="$tmp/repo"
    DEFAULT_DOTFILES=("$tmp/dotfiles")
    FAST=0
    JSON=0
    QUIET=0

    local f1 f2 pass=0
    f1="$(mktemp "${TMPDIR:-/tmp}/secret_scan_selftest_f1.XXXXXX")"
    FINDINGS_FILE="$f1"
    scan_source_patterns
    scan_at_rest
    check_permissions

    if awk -F'\t' '$1=="1" && $3 ~ /bad_denylist\.sh$/' "$f1" | grep -q .; then
        pass=$((pass + 1))
    else
        echo "FAIL: denylist export capture not flagged (detector 1)"
    fi

    if awk -F'\t' '$3 ~ /good_allowlist\.sh$/' "$f1" | grep -q .; then
        echo "FAIL: allowlist export capture wrongly flagged"
    else
        pass=$((pass + 1))
    fi

    if awk -F'\t' '$1=="2" && $3 ~ /leaked_token\.env$/' "$f1" | grep -q .; then
        pass=$((pass + 1))
    else
        echo "FAIL: ghp_-shaped token not flagged (detector 2)"
    fi

    if awk -F'\t' '$1=="3" && $3 ~ /insecure_perms\.env$/' "$f1" | grep -q .; then
        pass=$((pass + 1))
    else
        echo "FAIL: mode-644 credential file not flagged (detector 3)"
    fi

    local out
    out="$(FINDINGS_FILE="$f1" JSON=0 QUIET=0 print_report 2>&1)"
    apply_fixes >/dev/null 2>&1 || true

    local mode_after
    mode_after="$(file_mode "$tmp/dotfiles/insecure_perms.env")"
    if [ "$mode_after" = "600" ]; then
        pass=$((pass + 1))
    else
        echo "FAIL: chmod 600 not applied by --fix (mode=$mode_after)"
    fi

    f2="$(mktemp "${TMPDIR:-/tmp}/secret_scan_selftest_f2.XXXXXX")"
    FINDINGS_FILE="$f2"
    scan_source_patterns
    scan_at_rest
    check_permissions
    if awk -F'\t' '$1=="3" && $3 ~ /insecure_perms\.env$/' "$f2" | grep -q .; then
        echo "FAIL: still flagged as bad-permissions after --fix + re-scan"
    else
        pass=$((pass + 1))
    fi

    if awk -F'\t' '$1=="4" && $3 ~ /commented\.env$/' "$f2" | grep -q .; then
        pass=$((pass + 1))
    else
        echo "FAIL: commented-out credential assignment not flagged (detector 4)"
    fi

    # Line 2 of commented.env is `API_KEY=$SOME_VAR` -- indirection, not a
    # literal. Line 1 (the commented-out secret) legitimately also matches
    # the generic cred-shape detector as detector 2 -- a literal value is
    # exposed whether or not a `#` precedes it -- so this assertion must
    # check line 2 specifically, not "no detector-2 finding anywhere in
    # the file".
    if awk -F'\t' '$1=="2" && $3 ~ /commented\.env$/ && $4=="2"' "$f2" | grep -q .; then
        echo "FAIL: \$VAR indirection wrongly flagged as a literal credential"
    else
        pass=$((pass + 1))
    fi

    if grep -q "prose\.txt" "$f2"; then
        echo "FAIL: prose containing the word 'password' was over-matched"
    else
        pass=$((pass + 1))
    fi

    local out_json
    out_json="$(FINDINGS_FILE="$f2" JSON=1 print_report 2>&1)"
    case "$out $out_json" in
        *"$sentinel"*) echo "FAIL: sentinel value leaked into stdout" ;;
        *) pass=$((pass + 1)) ;;
    esac

    local err_capture
    err_capture="$( { scan_at_rest; } 2>&1 1>/dev/null )"
    case "$err_capture" in
        *"$sentinel"*) echo "FAIL: sentinel value leaked into stderr" ;;
        *) pass=$((pass + 1)) ;;
    esac

    if [ -f "$LOG_FILE" ] && grep -q "$sentinel" "$LOG_FILE" 2>/dev/null; then
        echo "FAIL: sentinel value leaked into the log file"
    else
        pass=$((pass + 1))
    fi

    rm -rf "$tmp" "$f1" "$f2" 2>/dev/null || true

    echo "selftest: ${pass}/12 PASS"
    [ "$pass" -eq 12 ]
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if [ "$MODE" = "selftest" ]; then
    run_selftest
    exit $?
fi

FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/secret_exposure_scan.XXXXXX")"
trap 'rm -f "$FINDINGS_FILE"' EXIT

scan_source_patterns
scan_at_rest
check_permissions

if [ "$MODE" = "fix" ]; then
    apply_fixes
    remaining="$(remaining_after_fix)"
    print_report
    [ "$remaining" -eq 0 ]
    exit $?
fi

total=$(wc -l < "$FINDINGS_FILE" | tr -d ' ')
print_report
[ "$total" -eq 0 ]
exit $?
