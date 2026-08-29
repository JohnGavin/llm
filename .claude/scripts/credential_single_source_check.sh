#!/usr/bin/env bash
# credential_single_source_check.sh — deterministic check for the
# "Acceptance" section of JohnGavin/llm#949 ("[P0] Credential sprawl: make
# ~/.config/secrets.env the single source of truth"). That issue's root
# cause was the SAME credential defined in multiple disagreeing places
# (GMAIL_APP_PASSWORD in 6 files, 2 different values). Most of the
# remediation is done or deferred to credential rotation (see "Out of
# scope" below) — this script implements the one concrete deliverable
# still open: a check, not a human, watching for the sprawl to recur.
#
# Asserts, over a FIXED, EXPLICIT file set (not a repo-wide sweep —
# secret_exposure_scan.sh already does that broad sweep):
#   1. every credential-shaped NAME is assigned in exactly one file
#   2. ~/.config/secrets.env has one assignment per non-comment/blank line,
#      and ends with a trailing newline
#   3. no file OTHER than secrets.env assigns a credential-shaped name
#      (even once, even if not duplicated elsewhere)
#   4. no credential-shaped NAME=VALUE assignment sits on a comment line,
#      in any scanned file
#
# Scanned file set (llm#949's own list):
#   ~/.config/secrets.env        (the intended single source of truth)
#   ~/.zshenv
#   ~/.zshrc
#   ~/.config/positron/*.sh      (glob — directory may not exist)
#   ~/.claude/env/*.env          (glob)
#
# REUSE, NOT REIMPLEMENTATION, of the credential-shape heuristics already
# built and tested elsewhere in this repo:
#
#   - Check 1/3 (NAME-shape matching) calls name_segment_matches(), the
#     exact function defined in secret_exposure_scan.sh, extracted at
#     runtime via `sed` and sourced into THIS shell (see
#     extract_name_segment_matches() below). It is NOT copy-pasted: if
#     upstream's segment-matching logic changes, this check picks up the
#     change automatically, and the two scanners can never silently
#     diverge on what counts as a "credential-shaped name". Plain
#     `source secret_exposure_scan.sh` was rejected — that file is NOT
#     import-safe: it unconditionally runs a full scan (writes a
#     housekeeping_runs row, a findings tempfile, etc.) as soon as it is
#     read, with no `[ "${BASH_SOURCE[0]}" = "$0" ]` guard. Extracting just
#     the one small, pure, self-contained function (bash `printf` + one
#     `awk` call, no other function/global dependency) avoids that
#     side-effect entirely.
#
#   - Check 4 (commented-out credential) shells out to
#     `secret_exposure_scan.sh --scan --json --fast` and filters ITS
#     detector-4 findings down to files in this script's target set. That
#     detector already implements the exact NAME-AND-VALUE
#     (entropy/length/shape) heuristic this check needs, tested by that
#     script's own --selftest — reimplementing it here would be a second,
#     silently-divergeable copy of the same logic (the precise failure
#     shape secret_consumers.sh's own "defined exactly once" selftest,
#     llm#958, was written to prevent one layer up). `--fast` mode scans
#     exactly ~/.config, ~/.claude/env, ~/.zshenv, ~/.zshrc (its
#     DEFAULT_DOTFILES) — a superset of this script's target set — so no
#     scanner-side change was needed; this script just filters to the
#     files it cares about. Requires `jq` (already used throughout this
#     repo's scripts, e.g. audit_scheduled_workflows.sh,
#     branch_gc.sh) to parse the --json output; if jq or the scanner is
#     unavailable, that check is reported as its own INDETERMINATE
#     condition rather than silently skipped.
#
#   - Check 2 (secrets.env format) is a small, self-contained awk
#     equivalent of the "glued two-assignment" heuristic in
#     secrets_cache_regen.sh's _validate_fetch() — that function was NOT
#     reusable the same way: it is written to compare a freshly-fetched
#     CANDIDATE against the CURRENT cache (two files, plus a
#     _count_keys() dependency and a "don't shrink the key count" check
#     that has no meaning for a single static file), and
#     secrets_cache_regen.sh is, like secret_exposure_scan.sh, not
#     import-safe (`_main "$@"` runs unconditionally at the bottom of the
#     file, including a live `bws` network call on a bare source). The awk
#     block below intentionally mirrors that function's detection idea
#     (second UPPER_SNAKE_CASE token immediately followed by `=`, our
#     secret-naming convention) rather than inventing a new heuristic.
#
# NEVER prints a credential VALUE. Findings carry file, line number,
# variable NAME, and a fixed generic note (which may list OTHER files/line
# numbers for a duplicate — never a value) — the same no-leak-value
# contract as secret_exposure_scan.sh, verified the same way: --selftest
# plants a sentinel value and asserts it never reaches stdout or stderr.
#
# Usage: credential_single_source_check.sh [--selftest] [--json]
#
# Exit codes:
#   0  clean       — every scannable file was read and no violation found
#   1  violation   — at least one of checks 1-4 found something
#   2  indeterminate — nothing could be scanned at all (zero target files
#                      existed/were readable), OR every check clean but
#                      at least one target file/dependency could not be
#                      read/verified (see checks-must-distinguish-unknown:
#                      an unknown result must never present as "clean")
#
# Out of scope (see the dispatch that created this file for the fuller
# rationale — not re-litigated here):
#   - deciding BWS-vs-secrets.env authority (human policy call)
#   - collapsing ~/.claude/env/*.env into secrets.env (blocked pending
#     GMAIL_APP_PASSWORD rotation — this script correctly REPORTS that
#     duplication; it does not fix it)
#   - wiring this into session_init.sh or CI (natural follow-up, not done
#     here so this PR stays reviewable and focused)

set -uo pipefail

HOME_DIR="${HOME:-/Users/johngavin}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCANNER="${SCANNER:-${SCRIPT_DIR}/secret_exposure_scan.sh}"
SECRETS_ENV="${SECRETS_ENV:-${HOME_DIR}/.config/secrets.env}"

shopt -s nullglob

MODE="scan"
JSON=0

usage() {
    cat <<'EOF'
Usage: credential_single_source_check.sh [--selftest] [--json]
EOF
}

for arg in "$@"; do
    case "$arg" in
        --selftest) MODE="selftest" ;;
        --json) JSON=1 ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "credential_single_source_check: unknown argument: $arg" >&2
            usage >&2
            exit 2
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Reused heuristic: extract name_segment_matches() from secret_exposure_scan.sh
# ---------------------------------------------------------------------------

# extract_name_segment_matches SCANNER_PATH
# Pulls the name_segment_matches() function body verbatim out of the
# canonical scanner and `eval`s it into THIS shell's function namespace,
# WITHOUT ever running that script's main scan flow. Returns 1 (leaving
# name_segment_matches undefined) if the scanner is missing/unreadable or
# the function text can't be found — callers MUST treat that as
# indeterminate, never as "0 matches found".
extract_name_segment_matches() {
    local scanner="$1"
    [ -r "$scanner" ] || return 1
    local snippet
    snippet="$(sed -n '/^name_segment_matches() {/,/^}/p' "$scanner" 2>/dev/null)"
    [ -n "$snippet" ] || return 1
    eval "$snippet"
    declare -F name_segment_matches >/dev/null 2>&1
}

# heuristic_ready — 1 iff name_segment_matches was extracted AND passes a
# sanity check against two known cases (a real credential word, and a
# known non-credential lookalike). A silently-broken extraction (e.g. the
# upstream function got renamed or reformatted) must not masquerade as "0
# credential names found anywhere" — that is exactly the
# checks-must-distinguish-unknown failure shape.
heuristic_ready=0
if extract_name_segment_matches "$SCANNER"; then
    if name_segment_matches "API_KEY" && ! name_segment_matches "compat_mode"; then
        heuristic_ready=1
    fi
fi

# ---------------------------------------------------------------------------
# Target file set
# ---------------------------------------------------------------------------

# build_target_files — populates TARGET_FILES from the current HOME_DIR /
# SECRETS_ENV globals. Called fresh by both the real run and --selftest
# (which override HOME_DIR/SECRETS_ENV first) so the two paths share one
# definition of "what gets scanned".
build_target_files() {
    TARGET_FILES=("$SECRETS_ENV" "${HOME_DIR}/.zshenv" "${HOME_DIR}/.zshrc")
    local f
    for f in "${HOME_DIR}/.config/positron"/*.sh; do
        TARGET_FILES+=("$f")
    done
    for f in "${HOME_DIR}/.claude/env"/*.env; do
        TARGET_FILES+=("$f")
    done
}

# ---------------------------------------------------------------------------
# Findings / indeterminate sinks
#
# append_finding CHECK SEVERITY FILE LINE NAME NOTE — NOTE is a fixed,
# generic description; it may list OTHER files/lines for a duplicate name
# but NEVER a credential value. This is the single choke point for the
# no-leaked-value contract; every caller MUST respect it.
# ---------------------------------------------------------------------------

append_finding() {
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "$FINDINGS_FILE"
}

# append_indeterminate FILE REASON — FILE may be "-" for a check-level
# (not file-level) indeterminate condition (e.g. jq missing).
append_indeterminate() {
    printf '%s\t%s\n' "$1" "$2" >> "$INDETERMINATE_FILE"
}

# ---------------------------------------------------------------------------
# Check 1 + 3 — NAME-shape assignment scan (duplicate / outside-secrets.env)
# ---------------------------------------------------------------------------

# scan_name_assignments FILE — records one row (name, file, line) per
# LIVE (non-comment, non-blank) assignment whose NAME is credential-shaped
# per the reused name_segment_matches() heuristic. Matches regardless of
# the RHS shape (literal or $VAR reference) — a name is "assigned" either
# way; only the credential_exposure_scan.sh detectors care about the VALUE
# shape, and this check is about NAMES living in more than one place.
scan_name_assignments() {
    local file="$1"
    local lineno=0 line name
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*= ]]; then
            name="${BASH_REMATCH[2]}"
            if name_segment_matches "$name"; then
                printf '%s\t%s\t%s\n' "$name" "$file" "$lineno" >> "$ASSIGN_FILE"
            fi
        fi
    done < "$file"
}

# NAME_DUP_AWK — groups ASSIGN_FILE (name\tfile\tline) by name. Emits
# "DUP\t<name>\t<file:line;file:line;...>" when a name is assigned in more
# than one distinct file, or "OUTSIDE\t<name>\t<file:line;...>" when a
# name is assigned in exactly one file and that file is NOT secrets.env.
# A name assigned exactly once, in secrets.env, is fully compliant and
# emits nothing.
read -r -d '' NAME_DUP_AWK <<'AWKEOF' || true
{
  name = $1; file = $2; line = $3
  loc = file ":" line
  if (!(name in seen)) { order[++n] = name; seen[name] = 1 }
  fkey = name SUBSEP file
  if (!(fkey in filedone)) {
    filedone[fkey] = 1
    nfiles[name]++
    onlyfile[name] = file
  }
  alllocs[name] = (alllocs[name] == "" ? loc : alllocs[name] ";" loc)
}
END {
  for (i = 1; i <= n; i++) {
    name = order[i]
    if (nfiles[name] > 1) {
      print "DUP\t" name "\t" alllocs[name]
    } else if (onlyfile[name] != secrets_env) {
      print "OUTSIDE\t" name "\t" alllocs[name]
    }
  }
}
AWKEOF

evaluate_name_duplicates() {
    [ -s "$ASSIGN_FILE" ] || return 0
    local kind name locs
    while IFS=$'\t' read -r kind name locs; do
        [ -n "$kind" ] || continue
        case "$kind" in
            DUP)
                append_finding "1_DUPLICATE_NAME" "critical" "-" "-" "$name" \
                    "credential-shaped NAME assigned in more than one file: ${locs}"
                ;;
            OUTSIDE)
                append_finding "3_OUTSIDE_SECRETS_ENV" "high" "-" "-" "$name" \
                    "credential-shaped NAME assigned outside ${SECRETS_ENV}: ${locs}"
                ;;
        esac
    done < <(awk -F'\t' -v secrets_env="$SECRETS_ENV" "$NAME_DUP_AWK" "$ASSIGN_FILE")
}

# ---------------------------------------------------------------------------
# Check 2 — secrets.env format (one assignment per line + trailing newline)
# ---------------------------------------------------------------------------

# SECRETS_ENV_FORMAT_AWK — mirrors the "glued two-assignment" idea in
# secrets_cache_regen.sh's _validate_fetch() (see header comment for why
# that function itself could not be reused directly). Skips blank/comment
# lines; flags a line not starting with NAME= (after optional `export`)
# as malformed, and a line whose remainder contains a second
# UPPER_SNAKE_CASE (our secret-naming convention, >=4 chars) token
# immediately followed by `=` as a glued-together assignment.
read -r -d '' SECRETS_ENV_FORMAT_AWK <<'AWKEOF' || true
/^[[:space:]]*$/ { next }
/^[[:space:]]*#/ { next }
{
  line = $0
  sub(/^[[:space:]]*export[[:space:]]+/, "", line)
  if (line !~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
    print NR "\tmalformed"
    next
  }
  rest = line
  sub(/^[A-Za-z_][A-Za-z0-9_]*=/, "", rest)
  if (match(rest, /[A-Z_][A-Z0-9_]{3,}=/)) {
    print NR "\tglued"
  }
}
AWKEOF

check_secrets_env_format() {
    local file="$1"

    if [ -s "$file" ]; then
        # NOTE: `tail -c1 file | grep -q $'\n'` (the idiom
        # secrets_cache_regen.sh's _install_cache() also uses) is NOT a
        # reliable trailing-newline test -- a grep pattern that is
        # LITERALLY just a newline character is interpreted by both
        # /usr/bin/grep and ugrep as an empty alternation and matches
        # every line unconditionally, so that check always reports "has a
        # trailing newline" regardless of the actual byte (confirmed
        # empirically while building this script). `wc -l` on the last
        # byte alone is unambiguous: it is 1 iff that byte is a newline.
        local last_byte_is_nl
        last_byte_is_nl="$(tail -c1 "$file" | wc -l | tr -d ' ')"
        if [ "$last_byte_is_nl" -ne 1 ]; then
            append_finding "2_NO_TRAILING_NEWLINE" "high" "$file" "-" "-" \
                "file does not end with a trailing newline -- an append can glue directly onto the last line (the exact corruption class this check exists to catch)"
        fi
    fi

    local lnum kind
    while IFS=$'\t' read -r lnum kind; do
        [ -n "$lnum" ] || continue
        case "$kind" in
            glued)
                append_finding "2_MULTI_ASSIGN_LINE" "critical" "$file" "$lnum" "-" \
                    "line appears to contain a second assignment glued onto the first (values never printed) -- exactly the missing-trailing-newline corruption class"
                ;;
            malformed)
                append_finding "2_MALFORMED_LINE" "high" "$file" "$lnum" "-" \
                    "line does not start with NAME= (after optional export) -- not valid secrets.env syntax"
                ;;
        esac
    done < <(awk "$SECRETS_ENV_FORMAT_AWK" "$file")
}

# ---------------------------------------------------------------------------
# Check 4 — commented-out credential (reuse secret_exposure_scan.sh detector 4)
# ---------------------------------------------------------------------------

check_commented_credentials() {
    if [ ! -r "$SCANNER" ]; then
        append_indeterminate "-" "detector-4 (commented-credential) reuse check unavailable: ${SCANNER} not readable"
        return 0
    fi
    if ! command -v jq >/dev/null 2>&1; then
        append_indeterminate "-" "detector-4 (commented-credential) reuse check unavailable: jq not on PATH"
        return 0
    fi

    local out
    out="$(HOME="$HOME_DIR" bash "$SCANNER" --scan --json --fast 2>/dev/null)"
    if [ -z "$out" ]; then
        append_indeterminate "-" "detector-4 (commented-credential) reuse check unavailable: ${SCANNER} produced no output"
        return 0
    fi

    local f l n scanned match
    while IFS=$'\t' read -r f l n; do
        [ -n "${f:-}" ] || continue
        match=0
        for scanned in "${SCANNED_FILES[@]}"; do
            if [ "$f" = "$scanned" ]; then
                match=1
                break
            fi
        done
        [ "$match" -eq 1 ] || continue
        append_finding "4_COMMENTED_CREDENTIAL" "high" "$f" "$l" "$n" \
            "credential-shaped NAME with a credential-shaped value left on a comment line (reused from secret_exposure_scan.sh detector 4) -- commenting out is not removal"
    done < <(printf '%s' "$out" | jq -r '.findings[]? | select(.detector=="4") | [.file, .line, .name] | @tsv' 2>/dev/null)
}

# ---------------------------------------------------------------------------
# Main scan orchestration — populates FINDINGS_FILE / INDETERMINATE_FILE
# from the current HOME_DIR / SECRETS_ENV / SCANNER globals. Used by both
# the real run and --selftest.
# ---------------------------------------------------------------------------

perform_scan() {
    build_target_files
    SCANNED_FILES=()

    local f
    for f in "${TARGET_FILES[@]}"; do
        if [ -e "$f" ]; then
            if [ -r "$f" ]; then
                SCANNED_FILES+=("$f")
            else
                append_indeterminate "$f" "exists but is not readable (permission denied)"
            fi
        fi
        # else: does not exist -- not an error, silently skipped (a fresh
        # machine, or a positron/.claude-env dir that has never existed,
        # is a valid state, not an unknown one).
    done

    if [ "$heuristic_ready" -eq 1 ]; then
        for f in "${SCANNED_FILES[@]}"; do
            scan_name_assignments "$f"
        done
        evaluate_name_duplicates
    else
        append_indeterminate "-" "name_segment_matches heuristic unavailable (extraction from ${SCANNER} failed its sanity check) -- checks 1 and 3 could not run"
    fi

    for f in "${SCANNED_FILES[@]}"; do
        if [ "$f" = "$SECRETS_ENV" ]; then
            check_secrets_env_format "$f"
        fi
    done

    check_commented_credentials
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

print_report() {
    local total ind_total
    total=$(wc -l < "$FINDINGS_FILE" | tr -d ' ')
    ind_total=$(wc -l < "$INDETERMINATE_FILE" | tr -d ' ')

    if [ "$JSON" -eq 1 ]; then
        printf '{"findings":['
        local first=1 chk sev file line name note
        while IFS=$'\t' read -r chk sev file line name note; do
            [ "$first" -eq 1 ] || printf ','
            first=0
            printf '{"check":"%s","severity":"%s","file":"%s","line":"%s","name":"%s","note":"%s"}' \
                "$(json_escape "$chk")" "$(json_escape "$sev")" "$(json_escape "$file")" \
                "$(json_escape "$line")" "$(json_escape "$name")" "$(json_escape "$note")"
        done < "$FINDINGS_FILE"
        printf '],"indeterminate":['
        first=1
        local ifile ireason
        while IFS=$'\t' read -r ifile ireason; do
            [ "$first" -eq 1 ] || printf ','
            first=0
            printf '{"file":"%s","reason":"%s"}' "$(json_escape "$ifile")" "$(json_escape "$ireason")"
        done < "$INDETERMINATE_FILE"
        printf ']}\n'
        return 0
    fi

    if [ "$total" -eq 0 ] && [ "$ind_total" -eq 0 ]; then
        echo "credential-single-source-check: clean -- 0 violations, 0 indeterminate"
        return 0
    fi

    echo "credential-single-source-check: ${total} violation(s), ${ind_total} indeterminate"
    if [ "$total" -gt 0 ]; then
        echo "--- violations ---"
        local chk sev file line name note
        while IFS=$'\t' read -r chk sev file line name note; do
            printf '  [%s] %s %s:%s %s -- %s\n' "$sev" "$chk" "$file" "$line" "$name" "$note"
        done < "$FINDINGS_FILE"
    fi
    if [ "$ind_total" -gt 0 ]; then
        echo "--- indeterminate ---"
        local ifile ireason
        while IFS=$'\t' read -r ifile ireason; do
            printf '  %s -- %s\n' "$ifile" "$ireason"
        done < "$INDETERMINATE_FILE"
    fi
}

# ---------------------------------------------------------------------------
# --selftest
# ---------------------------------------------------------------------------

run_selftest() {
    local pass=0 total=0
    local tmp
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/cred_single_source_selftest.XXXXXX")"

    mkdir -p "$tmp/.config/positron" "$tmp/.claude/env"

    local sentinel="SENTINEL_zQ9xxNeverPrintMe_7f3a"

    # secrets.env: SOLO_SECRET_KEY (compliant, single file = secrets.env),
    # MY_API_TOKEN (will be duplicated by .zshrc below), and a glued
    # two-assignment line with NO trailing newline -- exercises check 2
    # end to end in one fixture (the exact real-world corruption shape).
    printf '%s\n%s\n%s' \
        'export MY_API_TOKEN=value_in_secrets_env' \
        'SOLO_SECRET_KEY=onlyhere123456' \
        'GLUED_TOKEN=abcGLUED_SECRET_TWO=xyz' \
        > "$tmp/.config/secrets.env"
    # (no trailing newline -- the printf above has none after the 3rd %s)

    # .zshrc: duplicates MY_API_TOKEN (check 1), and carries a commented-out
    # credential-shaped assignment (check 4) -- same fixture shape as
    # secret_exposure_scan.sh's own --selftest for detector 4.
    cat > "$tmp/.zshrc" <<'EOF'
export PATH="$PATH:/usr/local/bin"
alias ll='ls -la'
export MY_API_TOKEN=value_in_zshrc
# API_KEY=sk-1234567890ABCDEFGHIJ
EOF

    # .zshenv: a credential-shaped name assigned ONLY here (never in
    # secrets.env) -- check 3 (outside-secrets.env), single-file case.
    cat > "$tmp/.zshenv" <<'EOF'
export ROGUE_PASSWORD=oops123456789012
EOF

    # .claude/env/job.env: the sentinel VALUE lives here, assigned to a
    # credential-shaped name that is (correctly) only defined in this one
    # file -- an OUTSIDE_SECRETS_ENV finding, same real-world shape as the
    # still-blocked GMAIL_APP_PASSWORD case this script is EXPECTED to
    # keep reporting (see header "Out of scope"). The point of this
    # fixture is solely to prove the sentinel VALUE never reaches output.
    cat > "$tmp/.claude/env/job.env" <<EOF
AWS_SECRET_ACCESS_KEY=${sentinel}
EOF

    # positron/broken.sh: exists, unreadable -- check 7's indeterminate case.
    echo "irrelevant content" > "$tmp/.config/positron/broken.sh"
    chmod 000 "$tmp/.config/positron/broken.sh"

    HOME_DIR="$tmp"
    SECRETS_ENV="$tmp/.config/secrets.env"
    FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/cred_single_source_selftest_f.XXXXXX")"
    INDETERMINATE_FILE="$(mktemp "${TMPDIR:-/tmp}/cred_single_source_selftest_i.XXXXXX")"
    ASSIGN_FILE="$(mktemp "${TMPDIR:-/tmp}/cred_single_source_selftest_a.XXXXXX")"

    local out err stderr_file
    stderr_file="$(mktemp "${TMPDIR:-/tmp}/cred_single_source_selftest_err.XXXXXX")"
    out="$(perform_scan 2>"$stderr_file")"
    err="$(cat "$stderr_file")"

    total=$((total + 1))
    if [ "$heuristic_ready" -eq 1 ]; then
        pass=$((pass + 1))
    else
        echo "FAIL: name_segment_matches extraction/sanity check did not succeed -- cannot trust any downstream assertion"
    fi

    total=$((total + 1))
    if awk -F'\t' '$1=="1_DUPLICATE_NAME" && $5=="MY_API_TOKEN"' "$FINDINGS_FILE" | grep -q .; then
        pass=$((pass + 1))
    else
        echo "FAIL: MY_API_TOKEN duplicated across secrets.env + .zshrc was not reported"
    fi

    total=$((total + 1))
    if awk -F'\t' '$5=="SOLO_SECRET_KEY"' "$FINDINGS_FILE" | grep -q .; then
        echo "FAIL: SOLO_SECRET_KEY (single file, IS secrets.env) was wrongly flagged"
    else
        pass=$((pass + 1))
    fi

    total=$((total + 1))
    if awk -F'\t' '$1=="3_OUTSIDE_SECRETS_ENV" && $5=="ROGUE_PASSWORD"' "$FINDINGS_FILE" | grep -q .; then
        pass=$((pass + 1))
    else
        echo "FAIL: ROGUE_PASSWORD (assigned only in .zshenv, never secrets.env) was not reported as outside-secrets.env"
    fi

    total=$((total + 1))
    if awk -F'\t' '$1=="2_NO_TRAILING_NEWLINE"' "$FINDINGS_FILE" | grep -q .; then
        pass=$((pass + 1))
    else
        echo "FAIL: missing trailing newline on secrets.env was not reported"
    fi

    total=$((total + 1))
    if awk -F'\t' '$1=="2_MULTI_ASSIGN_LINE"' "$FINDINGS_FILE" | grep -q .; then
        pass=$((pass + 1))
    else
        echo "FAIL: glued two-assignment line in secrets.env was not reported"
    fi

    total=$((total + 1))
    if awk -F'\t' '$1=="4_COMMENTED_CREDENTIAL"' "$FINDINGS_FILE" | grep -q .; then
        pass=$((pass + 1))
    else
        echo "FAIL: commented-out credential assignment in .zshrc was not reported (detector-4 reuse)"
    fi

    total=$((total + 1))
    if grep -q . "$INDETERMINATE_FILE" && awk -F'\t' '$1 ~ /broken\.sh$/' "$INDETERMINATE_FILE" | grep -q .; then
        pass=$((pass + 1))
    else
        echo "FAIL: unreadable positron/broken.sh was not reported as indeterminate"
    fi

    total=$((total + 1))
    local out_json report_text
    JSON=1
    out_json="$(print_report)"
    JSON=0
    report_text="$(print_report)"
    case "${out}${err}${out_json}${report_text}" in
        *"$sentinel"*)
            echo "FAIL: sentinel value leaked into stdout, stderr, or a report"
            ;;
        *)
            pass=$((pass + 1))
            ;;
    esac

    total=$((total + 1))
    local exit_would_be
    if [ "$(wc -l < "$FINDINGS_FILE" | tr -d ' ')" -gt 0 ]; then
        exit_would_be=1
    elif [ "$(wc -l < "$INDETERMINATE_FILE" | tr -d ' ')" -gt 0 ]; then
        exit_would_be=2
    else
        exit_would_be=0
    fi
    if [ "$exit_would_be" -eq 1 ]; then
        pass=$((pass + 1))
    else
        echo "FAIL: expected violations present -> exit-code-1 path, got exit_would_be=$exit_would_be"
    fi

    rm -f "$stderr_file"
    rm -rf "$tmp"
    rm -f "$FINDINGS_FILE" "$INDETERMINATE_FILE" "$ASSIGN_FILE"

    echo "selftest: ${pass}/${total} PASS"
    [ "$pass" -eq "$total" ]
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if [ "$MODE" = "selftest" ]; then
    run_selftest
    exit $?
fi

build_target_files
FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/cred_single_source_check.XXXXXX")"
INDETERMINATE_FILE="$(mktemp "${TMPDIR:-/tmp}/cred_single_source_check_ind.XXXXXX")"
ASSIGN_FILE="$(mktemp "${TMPDIR:-/tmp}/cred_single_source_check_assign.XXXXXX")"
trap 'rm -f "$FINDINGS_FILE" "$INDETERMINATE_FILE" "$ASSIGN_FILE"' EXIT

perform_scan

total_findings=$(wc -l < "$FINDINGS_FILE" | tr -d ' ')
total_indeterminate=$(wc -l < "$INDETERMINATE_FILE" | tr -d ' ')
total_scanned="${#SCANNED_FILES[@]}"

print_report

if [ "$total_scanned" -eq 0 ] && [ "$total_indeterminate" -eq 0 ]; then
    # Nothing existed at all -- not even an indeterminate (permission-
    # denied) file. A "0 violations" result here would be indistinguishable
    # from a genuinely clean single-source setup; per
    # checks-must-distinguish-unknown, report it as unknown instead.
    echo "credential-single-source-check: no scannable files found at all -- indeterminate" >&2
    exit 2
elif [ "$total_findings" -gt 0 ]; then
    exit 1
elif [ "$total_indeterminate" -gt 0 ]; then
    exit 2
else
    exit 0
fi
