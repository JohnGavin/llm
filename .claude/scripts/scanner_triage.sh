#!/usr/bin/env bash
# scanner_triage.sh -- fix, file or count the NEW findings of the latest
# secret_exposure_scan run according to .claude/state/scanner_policy.tsv
# (llm#1458 part 2). Output: "fixed N, filed M, tracked T, needs you K".
#
# Usage:
#   scanner_triage.sh [--dry-run | --apply] [--run-id ID] [--repo OWNER/REPO]
#
#   --dry-run  (DEFAULT) change nothing: no chmod, no issue, no comment. Open
#              tracking issues are still looked up (read-only), so a type that
#              already has one counts as tracked; a type that would need a new
#              issue, and a file that would be chmod'd, count as "needs you".
#   --apply    do it. The ONLY mutations are:
#                chmod 600 on a file that passes every safety condition below
#                (cap: 10 per run), and
#                one GitHub issue per (scanner, finding type), or at most one
#                comment per day on the open one.
#
# What the three classes mean (the table is the one home; this is the code):
#   auto-fix   chmod 600, but ONLY a file that is (a) an absolute-path regular
#              file, not a symlink, (b) outside any git work tree, (c) not
#              executable, (d) not under .claude/hooks/ or .claude/scripts/,
#              and (e) not already mode 600/400. A hook script wrongly
#              flagged by detector 2 would be broken by chmod 600, so
#              everything failing a condition stays "needs you".
#   auto-file  one issue per (scanner, finding type), found by a fingerprint
#              token in its title. Open issue exists -> at most one comment
#              per UTC day with the new count. Issue and comment bodies hold
#              ONLY scanner, finding type, count and run id: never a path,
#              a line, a value or a private name (the repo is public).
#   human      counted, nothing done. A finding type missing from the table
#              is human (default-permit is fail-open).
#
# Reads ~/.claude/logs/unified.duckdb READ-ONLY, using the same "new vs the
# last 7 days" query as the overnight email (lib/secret_scan_new_findings.sql).
# Writes ~/.claude/logs/scanner_triage/<YYYY-MM-DD>.json (the email reads it)
# and appends a DESTRUCTIVE: line per chmod to ~/.claude/logs/scanner_triage.log
# (path hash, not path; the exact revert command is in the JSON).
#
# Exit: 0 done | 2 usage | 3 INDETERMINATE (could not look, or a GitHub call
# failed; the reason is printed and recorded). Never reports "0 fixed" as
# success when it could not look.
#
# Env (tests point all of these at scratch fixtures): HOME, UNIFIED_DB_PATH,
# SCANNER_POLICY_FILE, SCANNER_TRIAGE_DIR, SCANNER_TRIAGE_REPO.
# Bash 3.2 compatible.

set -uo pipefail
export LC_ALL=C

SCANNER="secret_exposure_scan"
CAP=10
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
HOME_DIR="${HOME:-/Users/johngavin}"
DB="${UNIFIED_DB_PATH:-$HOME_DIR/.claude/logs/unified.duckdb}"
POLICY="${SCANNER_POLICY_FILE:-$SCRIPT_DIR/../state/scanner_policy.tsv}"
NEWSQL="$SCRIPT_DIR/lib/secret_scan_new_findings.sql"
OUTDIR="${SCANNER_TRIAGE_DIR:-$HOME_DIR/.claude/logs/scanner_triage}"
LOG="$HOME_DIR/.claude/logs/scanner_triage.log"
REPO="${SCANNER_TRIAGE_REPO:-JohnGavin/llm}"
TODAY="$(date -u +%Y-%m-%d)"

MODE="dry-run"
RUN_ID=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) MODE="dry-run" ;;
        --apply) MODE="apply" ;;
        --run-id) shift; RUN_ID="${1:-}" ;;
        --repo) shift; REPO="${1:-}" ;;
        -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
        *) echo "usage: scanner_triage.sh [--dry-run|--apply] [--run-id ID] [--repo OWNER/REPO]" >&2; exit 2 ;;
    esac
    shift
done
case "$REPO" in */*) ;; *) echo "usage: --repo needs OWNER/REPO" >&2; exit 2 ;; esac

T="$(mktemp -d "${TMPDIR:-/tmp}/scanner_triage.XXXXXX")" || { echo "INDETERMINATE: cannot create a temp dir" >&2; exit 3; }
trap 'rm -rf "$T"' EXIT
for f in new.tsv fixed.txt filed.txt tracked.txt already_ok.txt needs.txt reverts.txt done_files.txt notes.txt issues.txt; do : > "$T/$f"; done

json_escape() { sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
count_lines() { awk 'END{print NR}' "$1"; }
clean_type() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

# counts_obj FILE -> {"type":n,...} from a file with one type per line.
counts_obj() {
    if [ ! -s "$1" ]; then printf '{}'; return; fi
    sort "$1" | uniq -c | awk 'BEGIN{printf "{"} {printf "%s\"%s\":%d", (NR>1?",":""), $2, $1} END{printf "}"}'
}

# write_outcome STATUS WHY -- the JSON the overnight email reads.
write_outcome() {
    local status="$1" why="$2" out tmp reverts_json="" first=1 line
    [ -n "$RUN_ID" ] || return 0
    mkdir -p "$OUTDIR" 2>/dev/null || return 0
    out="$OUTDIR/$TODAY.json"
    tmp="$out.tmp.$$"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        if [ "$first" = 1 ]; then first=0; else reverts_json="$reverts_json,"; fi
        reverts_json="$reverts_json\"$(printf '%s' "$line" | json_escape)\""
    done < "$T/reverts.txt"
    (
        umask 077
        printf '{"date":"%s","run_id":"%s","scanner":"%s","mode":"%s","status":"%s","why":"%s",' \
            "$TODAY" "$RUN_ID" "$SCANNER" "$MODE" "$status" "$(printf '%s' "$why" | json_escape)"
        printf '"fixed":%s,"filed":%s,"tracked":%s,"already_ok":%s,"needs_you":%s,' \
            "$(count_lines "$T/fixed.txt")" "$(count_lines "$T/filed.txt")" \
            "$(count_lines "$T/tracked.txt")" "$(count_lines "$T/already_ok.txt")" \
            "$(count_lines "$T/needs.txt")"
        printf '"types":{"fixed":%s,"filed":%s,"tracked":%s,"already_ok":%s,"needs_you":%s},' \
            "$(counts_obj "$T/fixed.txt")" "$(counts_obj "$T/filed.txt")" \
            "$(counts_obj "$T/tracked.txt")" "$(counts_obj "$T/already_ok.txt")" \
            "$(counts_obj "$T/needs.txt")"
        printf '"reverts":[%s],"written_at":"%s"}\n' "$reverts_json" "$(now)"
    ) > "$tmp" 2>/dev/null && mv "$tmp" "$out" 2>/dev/null
}

fail3() {
    echo "INDETERMINATE: $1" >&2
    write_outcome "indeterminate" "$1"
    exit 3
}

command -v duckdb >/dev/null 2>&1 || fail3 "duckdb is not installed, cannot read the findings"
command -v git >/dev/null 2>&1 || fail3 "git is not installed, cannot tell whether a file is inside a work tree"
[ -r "$POLICY" ] || fail3 "policy table not readable: $POLICY"
[ -r "$NEWSQL" ] || fail3 "shared new-findings query not readable: $NEWSQL"
[ -f "$DB" ] || fail3 "findings database not found"

# dq SQL -- read-only query, tab-separated, no header.
dq() { duckdb -readonly -init /dev/null "$DB" -noheader -list -separator "$(printf '\t')" -c "$1" 2>"$T/dq.err"; }

if [ -z "$RUN_ID" ]; then
    RUN_ID="$(dq "SELECT id FROM housekeeping_runs WHERE task='$SCANNER' AND status='ok' ORDER BY started_at DESC LIMIT 1")" \
        || fail3 "findings database unreadable ($(head -c 200 "$T/dq.err" | tr '\n' ' '))"
    [ -n "$RUN_ID" ] || fail3 "no completed $SCANNER run in the database"
fi
case "$RUN_ID" in
    *[!A-Za-z0-9._:-]*|"") echo "usage: bad run id" >&2; exit 2 ;;
esac

ROWS="$(dq "SELECT coalesce(rows_written,-1) FROM housekeeping_runs WHERE id='$RUN_ID'")" \
    || fail3 "findings database unreadable ($(head -c 200 "$T/dq.err" | tr '\n' ' '))"
[ -n "$ROWS" ] || fail3 "run $RUN_ID is not in housekeeping_runs"
BASE="$(dq "SELECT count(*) FROM housekeeping_runs WHERE task='$SCANNER' AND status='ok' AND id<>'$RUN_ID'
            AND started_at < (SELECT started_at FROM housekeeping_runs WHERE id='$RUN_ID')
            AND started_at >= (SELECT started_at FROM housekeeping_runs WHERE id='$RUN_ID') - INTERVAL 7 DAY")" \
    || fail3 "findings database unreadable"
INTBL="$(dq "SELECT count(*) FROM secret_scan_findings WHERE run_id='$RUN_ID'")" \
    || fail3 "findings table unreadable ($(head -c 200 "$T/dq.err" | tr '\n' ' '))"
[ "${BASE:-0}" -gt 0 ] 2>/dev/null || fail3 "no earlier run in the last 7 days to tell new findings from known ones"
[ "$ROWS" = "$INTBL" ] || fail3 "heartbeat says $ROWS finding row(s) but the findings table holds $INTBL"

sed "s/@RUN_ID@/$RUN_ID/g" "$NEWSQL" > "$T/new.sql"
dq "$(cat "$T/new.sql")" > "$T/new.tsv" || fail3 "new-findings query failed ($(head -c 200 "$T/dq.err" | tr '\n' ' '))"

# class_of TYPE -> auto-fix | auto-file | human (unlisted, duplicated or
# unknown class is human).
class_of() {
    awk -F'\t' -v s="$SCANNER" -v t="$1" '
        NR>1 && $1==s && $2==t {c=$3; n++}
        END { if (n==1 && (c=="auto-fix" || c=="auto-file")) print c; else print "human" }' "$POLICY"
}

file_mode() {
    local m
    m="$(stat -c %a -- "$1" 2>/dev/null)" || m="$(stat -f %Lp -- "$1" 2>/dev/null)" || m=""
    printf '%s' "$m"
}

# safe_reason FILE -> ok:<mode> | already_ok | unsafe:<why>
safe_reason() {
    local f="$1" dir rdir out rc m
    case "$f" in /*) ;; *) echo "unsafe:not-absolute"; return ;; esac
    if [ -L "$f" ]; then echo "unsafe:symlink"; return; fi
    if [ ! -f "$f" ]; then echo "unsafe:not-a-regular-file"; return; fi
    case "$f" in */.claude/hooks/*|*/.claude/scripts/*) echo "unsafe:hook-or-script-path"; return ;; esac
    dir="$(dirname "$f")"
    rdir="$(cd "$dir" 2>/dev/null && pwd -P)" || { echo "unsafe:directory"; return; }
    case "$rdir/" in */.claude/hooks/*|*/.claude/scripts/*) echo "unsafe:hook-or-script-path"; return ;; esac
    out="$(env -u GIT_DIR -u GIT_WORK_TREE git -C "$rdir" rev-parse --is-inside-work-tree 2>&1)"
    rc=$?
    if [ "$rc" -eq 0 ]; then echo "unsafe:inside-git-repo"; return; fi
    case "$out" in
        *"not a git repository"*) ;;
        *) echo "unsafe:git-error"; return ;;
    esac
    m="$(file_mode "$f")"
    [ -n "$m" ] || { echo "unsafe:stat"; return; }
    case "$m" in 600|400) echo "already_ok"; return ;; esac
    if [ $(( 8#$m & 8#111 )) -ne 0 ]; then echo "unsafe:executable"; return; fi
    echo "ok:$m"
}

# ---------------------------------------------------------------------------
# Classify the new rows
# ---------------------------------------------------------------------------
: > "$T/fix_rows.tsv"
: > "$T/file_types.txt"
while IFS="$(printf '\t')" read -r det file line name; do
    [ -n "$name" ] || continue
    type="$(clean_type "$name")"
    cl="$(class_of "$name")"
    case "$cl" in
        auto-fix)  printf '%s\t%s\n' "$type" "$file" >> "$T/fix_rows.tsv" ;;
        auto-file) printf '%s\n' "$type" >> "$T/file_types.txt" ;;
        *)         printf '%s\n' "$type" >> "$T/needs.txt" ;;
    esac
done < "$T/new.tsv"

# ---------------------------------------------------------------------------
# auto-fix
# ---------------------------------------------------------------------------
mutations=0
while IFS="$(printf '\t')" read -r type file; do
    [ -n "$type" ] || continue
    if grep -qxF -- "$file" "$T/done_files.txt"; then
        printf '%s\n' "$type" >> "$T/fixed.txt"
        continue
    fi
    r="$(safe_reason "$file")"
    case "$r" in
        already_ok)
            printf '%s\n' "$type" >> "$T/already_ok.txt" ;;
        ok:*)
            old="${r#ok:}"
            if [ "$mutations" -ge "$CAP" ]; then
                printf '%s\n' "$type" >> "$T/needs.txt"
                echo "cap-reached" >> "$T/notes.txt"
            elif [ "$MODE" = "apply" ]; then
                if chmod 600 -- "$file" 2>/dev/null && [ "$(file_mode "$file")" = "600" ]; then
                    mutations=$((mutations + 1))
                    printf '%s\n' "$file" >> "$T/done_files.txt"
                    printf '%s\n' "$type" >> "$T/fixed.txt"
                    printf 'chmod %s %s\n' "$old" "$(sq "$file")" >> "$T/reverts.txt"
                    h="$(printf '%s' "$file" | shasum -a 256 | cut -c1-16)"
                    mkdir -p "$(dirname "$LOG")" 2>/dev/null
                    printf 'DESTRUCTIVE: %s chmod 600 type=%s path-hash=%s old-mode=%s revert="chmod %s \\"$P\\"" (P = the path whose sha256 starts %s; exact command in scanner_triage/%s.json)\n' \
                        "$(now)" "$type" "$h" "$old" "$old" "$h" "$TODAY" >> "$LOG" 2>/dev/null
                else
                    printf '%s\n' "$type" >> "$T/needs.txt"
                    echo "chmod-failed" >> "$T/notes.txt"
                fi
            else
                mutations=$((mutations + 1))
                printf '%s\n' "$type" >> "$T/needs.txt"
                echo "would-fix" >> "$T/notes.txt"
            fi ;;
        *)
            printf '%s\n' "$type" >> "$T/needs.txt"
            echo "${r#unsafe:}" >> "$T/notes.txt" ;;
    esac
done < "$T/fix_rows.tsv"

# ---------------------------------------------------------------------------
# auto-file: one issue per (scanner, type), deduplicated by a title token
# ---------------------------------------------------------------------------
gh_failed=""
if [ -s "$T/file_types.txt" ]; then
    if ! gh issue list --repo "$REPO" --state open --limit 500 --json number,title \
            --jq '.[] | "\(.number)\t\(.title)"' > "$T/open_issues.tsv" 2>"$T/gh.err"; then
        gh_failed="GitHub unavailable: $(head -c 200 "$T/gh.err" | tr '\n' ' ')"
    fi
fi
if [ -n "$gh_failed" ]; then
    cat "$T/file_types.txt" >> "$T/needs.txt"
else
    sort -u "$T/file_types.txt" > "$T/file_types_u.txt"
    while IFS= read -r type; do
        [ -n "$type" ] || continue
        n="$(grep -cxF -- "$type" "$T/file_types.txt")"
        token="sctr$(printf '%s' "$SCANNER/$type" | shasum -a 256 | cut -c1-10)"
        num="$(awk -F'\t' -v tok="$token" 'index($2, tok) {print $1; exit}' "$T/open_issues.tsv")"
        marker="scanner-triage-day:$TODAY"
        add_n() { i=0; while [ "$i" -lt "$n" ]; do printf '%s\n' "$type" >> "$1"; i=$((i + 1)); done; }
        if [ -n "$num" ]; then
            if [ "$MODE" = "apply" ]; then
                if gh issue view "$num" --repo "$REPO" --json body,comments \
                        --jq '.body, (.comments[].body)' > "$T/view.txt" 2>"$T/gh.err"; then
                    if grep -qF "$marker" "$T/view.txt"; then
                        action="already-commented-today"
                    else
                        printf 'Scanner: %s\nFinding type: %s\nNew findings: %s\nRun: %s\n\n%s\n' \
                            "$SCANNER" "$type" "$n" "$RUN_ID" "$marker" > "$T/body.txt"
                        if gh issue comment "$num" --repo "$REPO" --body-file "$T/body.txt" >/dev/null 2>"$T/gh.err"; then
                            action="commented"
                        else
                            action="comment-failed"
                        fi
                    fi
                else
                    action="view-failed"
                fi
                case "$action" in
                    commented|already-commented-today) add_n "$T/tracked.txt" ;;
                    *) add_n "$T/needs.txt"; gh_failed="GitHub call failed for an open tracking issue: $(head -c 200 "$T/gh.err" | tr '\n' ' ')" ;;
                esac
            else
                add_n "$T/tracked.txt"
            fi
        else
            if [ "$MODE" = "apply" ]; then
                printf 'Scanner: %s\nFinding type: %s\nNew findings: %s\nFirst seen in run: %s\n\nOpened by scanner_triage.sh (llm#1458). One issue per finding type; later runs add at most one comment per day. Details stay local.\n\n%s\n' \
                    "$SCANNER" "$type" "$n" "$RUN_ID" "$marker" > "$T/body.txt"
                if gh issue create --repo "$REPO" \
                        --title "Scanner triage: $SCANNER / $type [$token]" \
                        --body-file "$T/body.txt" >/dev/null 2>"$T/gh.err"; then
                    add_n "$T/filed.txt"
                else
                    add_n "$T/needs.txt"
                    gh_failed="GitHub issue create failed: $(head -c 200 "$T/gh.err" | tr '\n' ' ')"
                fi
            else
                add_n "$T/needs.txt"
                echo "would-file" >> "$T/notes.txt"
            fi
        fi
    done < "$T/file_types_u.txt"
fi

write_outcome "done" "${gh_failed:-}"
echo "scanner_triage: mode=$MODE run=$RUN_ID fixed $(count_lines "$T/fixed.txt"), filed $(count_lines "$T/filed.txt"), tracked $(count_lines "$T/tracked.txt"), needs you $(count_lines "$T/needs.txt")"
if [ -n "$gh_failed" ]; then
    echo "INDETERMINATE: $gh_failed" >&2
    exit 3
fi
exit 0
