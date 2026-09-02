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
# Usage: credential_single_source_check.sh [--selftest] [--json] [--quiet]
#
# Exit codes (the repo-wide 0/1/2/3 convention — see exit-code-conventions,
# llm#1140. This script previously used exit 2 for BOTH "bad arguments" and
# "indeterminate", the exact collision that rule was written to end; fixed
# here rather than left for the rule's own follow-up audit to catch):
#   0  PASS          — every scannable file was read and no violation found
#   1  FAIL          — at least one of checks 1-4 found something
#   2  usage error   — the caller invoked this wrongly (unknown argument)
#   3  INDETERMINATE — nothing could be scanned at all (zero target files
#                      existed/were readable), OR every check clean but
#                      at least one target file/dependency could not be
#                      read/verified (see checks-must-distinguish-unknown:
#                      an unknown result must never present as "clean").
#                      Scoped per-check, not blanket: a broken dependency
#                      (e.g. the reused scanner missing) only indeterminates
#                      the checks that actually needed it — a check
#                      answerable without that dependency (e.g. secrets.env's
#                      own trailing-newline/format check, which needs no
#                      external tool) still returns a determinate PASS/FAIL.
#
# --quiet prints ONE line only when there is something to report (a
# violation or an indeterminate condition) and stays silent when clean —
# same contract as secrets_cache_drift.sh's --quiet, for the same reason:
# a session-start banner that is always present trains the reader to
# ignore it. Exit codes are UNCHANGED in --quiet mode (still 0/1/3) so a
# caller that branches on the exit code gets the same distinctions either
# way; only the printed detail is suppressed.
#
# Out of scope (see the dispatch that created this file for the fuller
# rationale — not re-litigated here):
#   - collapsing ~/.claude/env/*.env into secrets.env (blocked pending
#     GMAIL_APP_PASSWORD rotation — this script correctly REPORTS that
#     duplication; it does not fix it)
#   - wiring this into CI (session_init.sh wiring is done — see
#     .claude/hooks/session_init.sh Phase 13f; CI is a separate follow-up)
#
# NOT out of scope, but already settled elsewhere (do not re-open): the
# BWS-vs-secrets.env authority decision. BWS is authoritative; secrets.env
# is a derived, regenerable cache — decided 2026-08-13 (commit 24780e6,
# predating this script), recorded in secrets-single-source.md's
# "Architecture" section, and evidenced by secrets.env's own generated
# header ("GENERATED by secrets_cache_regen.sh from Bitwarden Secrets
# Manager" / "DO NOT EDIT — edit in BWS and re-run this script"). This
# script does not re-verify that decision against BWS at runtime — it
# checks LOCAL file placement/format, which is answerable without ever
# reaching BWS (see the per-check INDETERMINATE scoping above).

set -uo pipefail

HOME_DIR="${HOME:-/Users/johngavin}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SELF="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]:-$0}")"
SCANNER="${SCANNER:-${SCRIPT_DIR}/secret_exposure_scan.sh}"
SECRETS_ENV="${SECRETS_ENV:-${HOME_DIR}/.config/secrets.env}"

# Housekeeping heartbeat target (llm#949, mirrors secret_exposure_scan.sh's
# llm#951 pattern). UNIFIED_DB_PATH lets --selftest redirect writes to a
# throwaway DB; must NEVER default to anything but the real unified.duckdb
# in production. Writing a row on EVERY invocation -- including a clean
# one -- is the point: "0 violations" must be distinguishable from "this
# check never ran", the exact failure shape llm#949's acceptance criteria
# exists to prevent one layer up (a check nobody is running is worth
# exactly as much as no check at all).
UNIFIED_DB="${UNIFIED_DB_PATH:-${HOME_DIR}/.claude/logs/unified.duckdb}"

shopt -s nullglob

MODE="scan"
JSON=0
QUIET=0

usage() {
    cat <<'EOF'
Usage: credential_single_source_check.sh [--selftest] [--json] [--quiet]
EOF
}

for arg in "$@"; do
    case "$arg" in
        --selftest) MODE="selftest" ;;
        --json) JSON=1 ;;
        --quiet) QUIET=1 ;;
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
# Housekeeping heartbeat (llm#949) — one housekeeping_runs row per
# invocation, including a clean one. Best-effort throughout: duckdb absent,
# the DB missing, or any write failure is swallowed and NEVER aborts the
# scan (`|| true`). _duckdb_ok / _run_id / _run_started are plain globals
# (not `local`) so --selftest can call these directly against a throwaway
# UNIFIED_DB_PATH without ever touching the real unified.duckdb.
# ---------------------------------------------------------------------------

_duckdb_ok=0
if command -v duckdb >/dev/null 2>&1 && [ -f "$UNIFIED_DB" ]; then
    _duckdb_ok=1
fi
_run_id=""
_run_started=""

# hk_run_start — insert the housekeeping_runs start row. No-op (leaves
# _run_id empty) if duckdb/the DB is unavailable; hk_run_end checks
# _run_id before doing anything, so it stays safe even when this is skipped.
hk_run_start() {
    [ "$_duckdb_ok" = "1" ] || return 0
    _run_id="$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    [ -n "$_run_id" ] || return 0
    _run_started="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
    duckdb -init /dev/null "$UNIFIED_DB" -c "
        INSERT OR IGNORE INTO housekeeping_runs
          (id, task, source_script, started_at, status, rows_written)
        VALUES (
          '${_run_id}',
          'credential_single_source_check',
          '${SELF}',
          TIMESTAMPTZ '${_run_started}',
          'ok',
          0
        );
    " >/dev/null 2>&1 || true
}

# hk_run_end STATUS ROWS_WRITTEN — update the row opened by hk_run_start.
# No-op if hk_run_start never ran (duckdb/DB unavailable). ROWS_WRITTEN is
# total_findings + total_indeterminate: a nonzero value distinguishes "ran,
# found something to report" from "ran, genuinely nothing to report" in
# any dashboard rollup that only has the one column.
hk_run_end() {
    [ "$_duckdb_ok" = "1" ] || return 0
    [ -n "$_run_id" ] || return 0
    local status="$1" rows="${2:-0}" ended
    ended="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
    duckdb -init /dev/null "$UNIFIED_DB" -c "
        UPDATE housekeeping_runs
        SET ended_at = TIMESTAMPTZ '${ended}',
            status = '${status}',
            rows_written = ${rows}
        WHERE id = '${_run_id}';
    " >/dev/null 2>&1 || true
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

    if [ "$QUIET" -eq 1 ]; then
        if [ "$total" -gt 0 ] || [ "$ind_total" -gt 0 ]; then
            echo "credential-single-source-check: ${total} violation(s), ${ind_total} indeterminate -- run credential_single_source_check.sh for detail"
        fi
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
        exit_would_be=3
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

    # -------------------------------------------------------------------
    # Subprocess-level exit-code tests (exit-code-conventions, llm#1140).
    # The assertions above exercise this script's INTERNAL decision logic
    # (perform_scan + the exit_would_be replica); they never actually
    # invoke the script and read its real $?. Per that rule's "Selftest
    # Requirement" -- assert the EXACT exit code for every state a script
    # distinguishes, not just non-zero -- these five calls run the real
    # bottom-of-file main flow as a subprocess for each of the four codes
    # this script uses (0/1/2/3), plus the "determinate despite a broken
    # dependency" corollary from checks-must-distinguish-unknown.
    # -------------------------------------------------------------------

    local sp_tmp
    sp_tmp="$(mktemp -d "${TMPDIR:-/tmp}/cred_single_source_sp.XXXXXX")"
    mkdir -p "$sp_tmp/.config"

    # Test: usage error (unknown flag) -> exit 2, never confused with
    # exit 3 (indeterminate) or exit 1 (a real finding).
    total=$((total + 1))
    bash "$SELF" --this-flag-does-not-exist >/dev/null 2>&1
    local rc_usage=$?
    if [ "$rc_usage" -eq 2 ]; then
        pass=$((pass + 1))
    else
        echo "FAIL: unknown argument should exit 2 (usage error), got $rc_usage"
    fi

    # Test: fully clean, fully working -> exit 0 (PASS). Real trailing
    # newline, one assignment, present ONLY in secrets.env, real SCANNER.
    total=$((total + 1))
    printf 'export CLEAN_ONLY_TOKEN=onlyhere1234\n' > "$sp_tmp/.config/secrets.env"
    local out_clean rc_clean
    out_clean="$(HOME="$sp_tmp" SECRETS_ENV="$sp_tmp/.config/secrets.env" SCANNER="$SCANNER" bash "$SELF" 2>&1)"
    rc_clean=$?
    if [ "$rc_clean" -eq 0 ]; then
        pass=$((pass + 1))
    else
        echo "FAIL: fully compliant fixture should exit 0 (PASS), got $rc_clean -- output: $out_clean"
    fi

    # Test: a real violation (duplicate name across two files) with a
    # WORKING scanner -> exit 1 (FAIL), not 3 -- a determinate finding
    # must never be reported as merely indeterminate.
    total=$((total + 1))
    mkdir -p "$sp_tmp/.config"
    printf 'export DUPED_TOKEN=onlyhere1234\n' > "$sp_tmp/.config/secrets.env"
    printf 'export DUPED_TOKEN=alsohere1234\n' > "$sp_tmp/.zshrc"
    local out_viol rc_viol
    out_viol="$(HOME="$sp_tmp" SECRETS_ENV="$sp_tmp/.config/secrets.env" SCANNER="$SCANNER" bash "$SELF" 2>&1)"
    rc_viol=$?
    rm -f "$sp_tmp/.zshrc"
    if [ "$rc_viol" -eq 1 ]; then
        pass=$((pass + 1))
    else
        echo "FAIL: DUPED_TOKEN duplicate should exit 1 (FAIL), got $rc_viol -- output: $out_viol"
    fi

    # Test: INDETERMINATE-ONLY path, falsified. SCANNER pointed at a
    # nonexistent path breaks BOTH the name_segment_matches extraction
    # (checks 1/3) and the detector-4 reuse (check 4) -- with secrets.env
    # otherwise fully compliant, this must produce ZERO findings and ONLY
    # indeterminate entries. Exit MUST be 3, and the report text must NOT
    # contain the word "clean" -- an unanswerable check reporting "clean"
    # is exactly the bug this whole dispatch exists to prevent.
    total=$((total + 1))
    printf 'export ANOTHER_CLEAN_TOKEN=onlyhere5678\n' > "$sp_tmp/.config/secrets.env"
    local out_ind rc_ind
    out_ind="$(HOME="$sp_tmp" SECRETS_ENV="$sp_tmp/.config/secrets.env" SCANNER="$sp_tmp/no-such-scanner.sh" bash "$SELF" 2>&1)"
    rc_ind=$?
    if [ "$rc_ind" -eq 3 ]; then
        pass=$((pass + 1))
    else
        echo "FAIL: broken-SCANNER-only fixture should exit 3 (INDETERMINATE), got $rc_ind -- output: $out_ind"
    fi
    total=$((total + 1))
    case "$out_ind" in
        *clean*)
            echo "FAIL: INDETERMINATE-only run's report text contained the word 'clean' -- unknown must never read as clean"
            ;;
        *)
            pass=$((pass + 1))
            ;;
    esac

    # Test: the checks-must-distinguish-unknown corollary -- "ask whether
    # the question is answerable without the missing thing". secrets.env
    # is missing its trailing newline (check 2, needs no external tool)
    # while SCANNER is STILL broken (checks 1/3/4 indeterminate). The
    # trailing-newline finding is answerable independent of SCANNER and
    # MUST still surface as a determinate FAIL (exit 1, finding text
    # present) rather than being swallowed into a blanket indeterminate.
    total=$((total + 1))
    printf 'export STANDALONE_TOKEN=onlyhere9012' > "$sp_tmp/.config/secrets.env"  # no trailing \n
    local out_partial rc_partial
    out_partial="$(HOME="$sp_tmp" SECRETS_ENV="$sp_tmp/.config/secrets.env" SCANNER="$sp_tmp/no-such-scanner.sh" bash "$SELF" 2>&1)"
    rc_partial=$?
    if [ "$rc_partial" -eq 1 ] && printf '%s' "$out_partial" | grep -q '2_NO_TRAILING_NEWLINE'; then
        pass=$((pass + 1))
    else
        echo "FAIL: trailing-newline violation should still surface as a determinate FAIL (exit 1, 2_NO_TRAILING_NEWLINE reported) even with SCANNER broken -- got rc=$rc_partial output: $out_partial"
    fi

    # Test: --quiet stays silent on a clean run, and prints exactly one
    # line (not the full multi-line report) when there is something to
    # report -- while the underlying exit code is UNCHANGED (still 3).
    total=$((total + 1))
    printf 'export QUIET_CLEAN_TOKEN=onlyhere3456\n' > "$sp_tmp/.config/secrets.env"
    local out_quiet_clean
    out_quiet_clean="$(HOME="$sp_tmp" SECRETS_ENV="$sp_tmp/.config/secrets.env" SCANNER="$SCANNER" bash "$SELF" --quiet 2>&1)"
    if [ -z "$out_quiet_clean" ]; then
        pass=$((pass + 1))
    else
        echo "FAIL: --quiet on a clean run should print nothing, got: $out_quiet_clean"
    fi

    total=$((total + 1))
    local out_quiet_ind rc_quiet_ind line_count_quiet_ind
    out_quiet_ind="$(HOME="$sp_tmp" SECRETS_ENV="$sp_tmp/.config/secrets.env" SCANNER="$sp_tmp/no-such-scanner.sh" bash "$SELF" --quiet 2>&1)"
    rc_quiet_ind=$?
    line_count_quiet_ind="$(printf '%s' "$out_quiet_ind" | grep -c .)"
    if [ "$rc_quiet_ind" -eq 3 ] && [ "$line_count_quiet_ind" -eq 1 ]; then
        pass=$((pass + 1))
    else
        echo "FAIL: --quiet on an indeterminate run should exit 3 and print exactly one line, got rc=$rc_quiet_ind lines=$line_count_quiet_ind output: $out_quiet_ind"
    fi

    # Test: heartbeat -- hk_run_start/hk_run_end write a housekeeping_runs
    # row on EVERY invocation, including this clean one, into a throwaway
    # DB (never the real unified.duckdb). Skipped gracefully (not FAILed)
    # when duckdb itself is unavailable in this environment -- that is an
    # environment fact, not a defect in the heartbeat wiring.
    total=$((total + 1))
    if command -v duckdb >/dev/null 2>&1; then
        local hb_db hb_rc hb_status
        hb_db="$(mktemp "${TMPDIR:-/tmp}/cred_single_source_hb.XXXXXX.duckdb")"
        rm -f "$hb_db"
        duckdb -init /dev/null "$hb_db" -c "$(cat "${SCRIPT_DIR}/housekeeping_schema_init.sql" 2>/dev/null)" >/dev/null 2>&1 || true
        printf 'export HEARTBEAT_TOKEN=onlyhere7890\n' > "$sp_tmp/.config/secrets.env"
        HOME="$sp_tmp" SECRETS_ENV="$sp_tmp/.config/secrets.env" SCANNER="$SCANNER" UNIFIED_DB_PATH="$hb_db" bash "$SELF" >/dev/null 2>&1
        hb_rc=$?
        hb_status="$(duckdb -init /dev/null -readonly -noheader -list "$hb_db" -c "SELECT status FROM housekeeping_runs WHERE task='credential_single_source_check' LIMIT 1;" 2>/dev/null | tr -d '[:space:]')"
        if [ "$hb_rc" -eq 0 ] && [ "$hb_status" = "ok" ]; then
            pass=$((pass + 1))
        else
            echo "FAIL: heartbeat row not written to housekeeping_runs on a clean run (rc=$hb_rc status='$hb_status')"
        fi
        rm -f "$hb_db"
    else
        pass=$((pass + 1))
        echo "  SKIP: duckdb not on PATH -- heartbeat wiring not exercised (best-effort by design, not a failure)"
    fi

    rm -rf "$sp_tmp"

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

hk_run_start

build_target_files
FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/cred_single_source_check.XXXXXX")"
INDETERMINATE_FILE="$(mktemp "${TMPDIR:-/tmp}/cred_single_source_check_ind.XXXXXX")"
ASSIGN_FILE="$(mktemp "${TMPDIR:-/tmp}/cred_single_source_check_assign.XXXXXX")"
trap 'rm -f "$FINDINGS_FILE" "$INDETERMINATE_FILE" "$ASSIGN_FILE"' EXIT

perform_scan

total_findings=$(wc -l < "$FINDINGS_FILE" | tr -d ' ')
total_indeterminate=$(wc -l < "$INDETERMINATE_FILE" | tr -d ' ')
total_scanned="${#SCANNED_FILES[@]}"

if [ "$total_scanned" -eq 0 ] && [ "$total_indeterminate" -eq 0 ]; then
    # Nothing existed at all -- not even an indeterminate (permission-
    # denied) file. A "0 violations" result here would be indistinguishable
    # from a genuinely clean single-source setup; per
    # checks-must-distinguish-unknown, report it as unknown instead. Checked
    # BEFORE print_report (rather than after, as this script previously
    # did) so the printed report never says "clean" one line before this
    # overrides it with "indeterminate" -- the two must never both be true
    # in the same run's output.
    echo "credential-single-source-check: no scannable files found at all -- indeterminate" >&2
    hk_run_end "ok" 0
    exit 3
fi

print_report
hk_run_end "ok" "$((total_findings + total_indeterminate))"

if [ "$total_findings" -gt 0 ]; then
    exit 1
elif [ "$total_indeterminate" -gt 0 ]; then
    exit 3
else
    exit 0
fi
