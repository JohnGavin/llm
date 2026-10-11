#!/usr/bin/env bash
# private_data_history_audit.sh — scheduled full-history PII audit (Layer 5).
#
# Wraps `private_data_scan.sh --full-history --tsv` in the housekeeping-
# framework pattern used by worktree_gc.sh / secret_exposure_scan.sh: a
# housekeeping_runs heartbeat row and a log line per run, so a scanner that
# silently stopped firing at its scheduled slot is distinguishable from a
# scanner that genuinely found nothing (zero-metric-evidence-or-defect,
# housekeeping-framework rule).
#
# This is the deepest, slowest layer: pre-commit/pre-push/CI only ever see
# NEW content going forward from the point they were installed. This audit
# is what catches PII that entered history BEFORE any of those layers
# existed -- exactly the shape of the 2026-08-22 incident (present for 4
# months before any control could have seen it).
#
# Runs WITH the deny-list (--require-denylist, the private_data_scan.sh
# default) because this always runs locally, with access to
# ~/.config/private_values.env -- unlike CI, which deliberately runs
# --no-denylist (see private-data-scanning.md).
#
# This script never auto-remediates. There is no safe machine fix for PII
# already in published history -- remediation is always a human decision
# among the options already documented in repo-visibility-gate.md's "The
# audit itself" section (orphan-squash / git filter-repo / accept and
# publish-private instead). This script's job ends at REPORTING.
#
# ─── Per-finding identity (why this is not a count diff) ───────────────────
# Full history holds hundreds of long-standing findings. Reporting the total
# every week can never clear, and "4 new" computed as total-minus-last-total
# cannot say WHICH findings are new (a +10/-6 week also reads "4 new"), so a
# genuinely new leak hides in the standing noise. Instead every finding gets a
# stable fingerprint -- sha256(repo|rule|src|<sha12>:<path>|line), which does
# NOT contain the matched value -- recorded in the local-only table
# private_data_history_findings (unified.duckdb). A finding is NEW iff its
# fingerprint was never recorded before. Only NEW findings are listed in
# full; known ones are summarised by (rule, src, count).
#
# status lifecycle: new -> known (seen again on a later run) -> acknowledged
# (a human triaged it with --ack). A new finding is therefore reported by
# exactly one run; the log line and the heartbeat carry the count.
#
# ─── Exit codes (exit-code-conventions / checks-must-distinguish-unknown) ───
#   0  ran; no NEW findings (known / acknowledged ones may exist -- the log
#      line says how many)
#   1  ran; >= 1 NEW finding
#   2  usage error (bad flag, bad --ack value, --ack matching no finding)
#   3  INDETERMINATE: new-vs-known cannot be determined -- scanner missing,
#      crashed or exited with an unexpected code, scanner output truncated or
#      malformed, scan truncated (--max-commits), DB missing/unwritable, the
#      findings table missing, or no baseline established yet. Never reported
#      as findings and never as clean.
# private_data_scan.sh itself overloads exit 1 (findings AND fail-closed
# internal errors, because hooks treat any non-zero as "block"); this wrapper
# disambiguates by REQUIRING the scanner's 'private-data-scan: N finding(s)'
# summary line plus exactly N FINDING rows: exit 1 without them is an error.
#
# Usage:
#   private_data_history_audit.sh              # scan + report (dry-run label)
#   private_data_history_audit.sh --apply      # same scan; exists only to match
#                                              # the housekeeping dry-run/apply
#                                              # convention -- nothing is
#                                              # destructive in either mode
#   private_data_history_audit.sh --baseline   # seed: mark every CURRENT
#                                              # finding 'known' (exit 0). Run
#                                              # ONCE after deploy; without a
#                                              # baseline a normal run exits 3
#   private_data_history_audit.sh --all-public [--baseline]
#                                              # llm#1367/#1372: audit EVERY public
#                                              # repo of the owner, public forks of
#                                              # them and public gists, each as a
#                                              # fresh `git clone --mirror` from
#                                              # GitHub (all refs, incl. refs/pull/*;
#                                              # cached under ~/.cache/
#                                              # private_data_history_audit/ and
#                                              # refreshed with `remote update`).
#                                              # Ledger repo = owner/name or
#                                              # gist:<id>. Per-unit outcome PASS /
#                                              # FAIL / INDETERMINATE; a unit that
#                                              # cannot be enumerated, cloned or
#                                              # scanned is never clean. Baseline is
#                                              # PER REPO: a repo with no ledger rows
#                                              # and no baseline marker is
#                                              # INDETERMINATE until a run with
#                                              # --baseline. Summary line:
#                                              # repos=N clean=a new_findings=b indeterminate=c
#                                              # Exit 1 if any NEW finding, else 3 if
#                                              # any unit INDETERMINATE, else 0.
#                                              # Env: PDHA_OWNER, PDHA_CACHE_DIR.
#   private_data_history_audit.sh --ack <fingerprint> [--ack <fp> ...]
#   private_data_history_audit.sh --ack-file <file>   # one fingerprint per line
#   private_data_history_audit.sh --selftest
# A fingerprint may be the full 64 hex characters or an unambiguous prefix of
# at least 12 (the run output prints the first 16).
#
# Prerequisite: the table exists (bash .claude/scripts/housekeeping_schema_apply.sh).
#
# Log: ~/.claude/logs/private_data_history_audit.log
#      line: mode=... findings=<total> new=<n> known=<n> acknowledged=<n> status=... rc=...
# Housekeeping: housekeeping_runs (task='private_data_history_audit';
#   rows_written = NEW findings; status 'partial' = INDETERMINATE). A
#   --baseline run is recorded as task='private_data_history_baseline'.
# Delivered launchd plist (NOT installed by this dispatch):
#   .claude/launchd/com.claude.private-data-history-audit.plist
#
# Note (JohnGavin/llm#1204): the non-deterministic-finding-count bug (587 vs
# 174 on an identical repo state) was in private_data_scan.sh's old default
# MAX_COMMITS=2000 cap; fixed there. This wrapper never passes --max-commits.
#
# Origin: 2026-08-22 PII incident.

set -uo pipefail

# PDHA_EXTRA_PATH: prepended (selftest puts a stub `gh` first). /opt/homebrew/bin
# stays on the PATH for pdftotext (document-format gate) under launchd.
export PATH="${PDHA_EXTRA_PATH:+${PDHA_EXTRA_PATH}:}/nix/var/nix/profiles/default/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

HOME_DIR="${HOME:-/Users/johngavin}"
LOG_DIR="${HOME_DIR}/.claude/logs"
LOG_FILE="${LOG_DIR}/private_data_history_audit.log"
UNIFIED_DB="${UNIFIED_DB_PATH:-${HOME_DIR}/.claude/logs/unified.duckdb}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCANNER="${SCANNER:-${SCRIPT_DIR}/private_data_scan.sh}"
SCHEMA_SQL="${SCRIPT_DIR}/housekeeping_schema_init.sql"
GREP="${GREP:-grep}"

TABLE="private_data_history_findings"

APPLY=0
SELFTEST=0
BASELINE=0
ALL_PUBLIC=0
ACK_ARGS=()
ACK_FILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --apply) APPLY=1; shift ;;
        --selftest) SELFTEST=1; shift ;;
        --baseline) BASELINE=1; shift ;;
        --all-public) ALL_PUBLIC=1; shift ;;
        --ack)
            if [ $# -lt 2 ]; then echo "private_data_history_audit: --ack needs a fingerprint" >&2; exit 2; fi
            ACK_ARGS+=("$2"); shift 2 ;;
        --ack-file)
            if [ $# -lt 2 ]; then echo "private_data_history_audit: --ack-file needs a file" >&2; exit 2; fi
            ACK_FILE="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: private_data_history_audit.sh [--apply] [--baseline] [--all-public] [--ack FP]... [--ack-file F] [--selftest]"
            exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [ "$ALL_PUBLIC" -eq 1 ] && { [ "${#ACK_ARGS[@]}" -gt 0 ] || [ -n "$ACK_FILE" ]; }; then
    echo "private_data_history_audit: --all-public and --ack are mutually exclusive" >&2
    exit 2
fi
if [ "$BASELINE" -eq 1 ] && { [ "${#ACK_ARGS[@]}" -gt 0 ] || [ -n "$ACK_FILE" ]; }; then
    echo "private_data_history_audit: --baseline and --ack are mutually exclusive" >&2
    exit 2
fi

# PDHA_CHILD=1: this process is one per-repo scan spawned by --all-public. It
# tags its log lines with the repo and writes NO heartbeat (the parent writes
# one for the whole run, so rows_written still equals the ledger's new rows).
CHILD="${PDHA_CHILD:-}"
log_line() {
    local pfx=""
    [ -n "$CHILD" ] && pfx="repo=${PDHA_REPO_NAME:-unknown} "
    { mkdir -p "$LOG_DIR" 2>/dev/null
      printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" "${pfx}$1" >> "$LOG_FILE"
    } 2>/dev/null || true
}

_duckdb_ok=0
command -v duckdb >/dev/null 2>&1 && [ -f "$UNIFIED_DB" ] && [ -z "$CHILD" ] && _duckdb_ok=1
_run_id=""
HK_TASK="private_data_history_audit"

hk_run_start() {
    [ "$_duckdb_ok" = "1" ] || return 0
    _run_id="$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    [ -n "$_run_id" ] || return 0
    duckdb -init /dev/null "$UNIFIED_DB" -c "
        INSERT OR IGNORE INTO housekeeping_runs
          (id, task, source_script, started_at, status, rows_written)
        VALUES ('${_run_id}', '${HK_TASK}', '${SCRIPT_DIR}/private_data_history_audit.sh',
                current_timestamp, 'ok', 0);
    " >/dev/null 2>&1 || true
}

hk_run_end() {
    [ "$_duckdb_ok" = "1" ] || return 0
    [ -n "$_run_id" ] || return 0
    duckdb -init /dev/null "$UNIFIED_DB" -c "
        UPDATE housekeeping_runs SET ended_at = current_timestamp, status = '$1', rows_written = ${2:-0}
        WHERE id = '${_run_id}';
    " >/dev/null 2>&1 || true
}

# sql_quote STRING -> STRING with single quotes doubled (for SQL literals)
sql_quote() { printf '%s' "$1" | sed "s/'/''/g"; }

# ---------------------------------------------------------------------------
# --selftest
# ---------------------------------------------------------------------------
if [ "$SELFTEST" -eq 1 ]; then
    pass=0; total=0
    _check() { total=$((total + 1)); if [ "$1" = "0" ]; then pass=$((pass + 1)); echo "PASS  $2"; else echo "FAIL  $2"; fi; }
    # _expect_rc EXPECTED ACTUAL NAME  -- exact exit code, not merely non-zero
    _expect_rc() {
        if [ "$2" = "$1" ]; then _check 0 "$3 (rc=$2)"; else _check 1 "$3 (expected rc=$1, got rc=$2)"; fi
    }

    if ! command -v duckdb >/dev/null 2>&1; then
        echo "INDETERMINATE: duckdb not on PATH -- selftest cannot run"
        exit 3
    fi

    sb="$(mktemp -d "${TMPDIR:-/tmp}/pds_audit_selftest.XXXXXX")"
    trap 'rm -rf "$sb"' EXIT
    mkdir -p "$sb/home"
    # The selftest commits PII-shaped fixtures into synthetic repos. A global
    # core.hooksPath (the PII pre-commit, llm#1365) would block those commits
    # and silently turn the real-scanner checks into false failures.
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    SELF="$0"
    DB="$sb/unified.duckdb"
    # The REAL schema file builds the sandbox DB: this also exercises the DDL.
    if duckdb -init /dev/null "$DB" < "$SCHEMA_SQL" >"$sb/schema.out" 2>&1; then
        _check 0 "housekeeping_schema_init.sql applies to a fresh sandbox DB (creates the findings table)"
    else
        _check 1 "housekeeping_schema_init.sql failed to apply: $(head -3 "$sb/schema.out")"
    fi

    # Fake scanner: behaviour chosen by FAKE_MODE, findings read from FAKE_ROWS
    # (tab-separated: src sev loc line rule note).
    cat > "$sb/fake_scan.sh" <<'EOF'
#!/usr/bin/env bash
case "${FAKE_MODE:-findings}" in
  clean)
    echo "private-data-scan: scanned=3/3 commits (100%)"
    echo "private-data-scan: clean -- 0 findings"
    exit 0 ;;
  findings)
    n=$(wc -l < "$FAKE_ROWS" | tr -d ' ')
    echo "private-data-scan: scanned=3/3 commits (100%)"
    echo "private-data-scan: $n finding(s)"
    awk -F'\t' 'BEGIN{OFS="\t"} {print "FINDING",$1,$2,$3,$4,$5,$6}' "$FAKE_ROWS"
    exit 1 ;;
  private_findings)   # private repo: findings reported but exit 0
    n=$(wc -l < "$FAKE_ROWS" | tr -d ' ')
    echo "private-data-scan: $n finding(s)"
    awk -F'\t' 'BEGIN{OFS="\t"} {print "FINDING",$1,$2,$3,$4,$5,$6}' "$FAKE_ROWS"
    exit 0 ;;
  crash)
    echo "SELF-CHECK FAILED: detector cannot detect its own fixture" >&2
    exit 1 ;;
  blocked)
    echo "BLOCKED (fail-closed): deny-list is missing" >&2
    exit 1 ;;
  trunc)
    echo "private-data-scan: scanned=1/3 commits (33%) -- TRUNCATED"
    echo "private-data-scan: INDETERMINATE -- scan was truncated" >&2
    exit 3 ;;
  usage) exit 2 ;;
  mismatch)   # header promises 5 rows, only 1 delivered (truncated pipe)
    echo "private-data-scan: 5 finding(s)"
    printf 'FINDING\tgeneric\thigh\taaaaaaaaaaaa:x.txt\t1\tuk-postcode\tn\n'
    exit 1 ;;
  silent0) exit 0 ;;   # exit 0 but never says clean -- not trusted
esac
EOF
    chmod +x "$sb/fake_scan.sh"

    # Synthetic rows. Paths are invented; no real data.
    R3="$sb/rows3.tsv"
    printf 'generic\thigh\taaaaaaaaaaaa:docs/alpha.txt\t3\tuk-postcode\tnote\n'  > "$R3"
    printf 'generic\tcritical\tbbbbbbbbbbbb:docs/beta.txt\t7\te164-phone\tnote\n' >> "$R3"
    printf 'denylist\tcritical\tcccccccccccc:docs/gamma.txt\t1\tknown-value\tnote\n' >> "$R3"
    R4="$sb/rows4.tsv"
    cp "$R3" "$R4"
    printf 'generic\thigh\tdddddddddddd:docs/delta.txt\t2\tiban\tnote\n' >> "$R4"

    # run_audit MODE ROWS ARGS... ; sets $arc and writes $sb/out $sb/err
    run_audit() {
        local mode="$1" rows="$2"; shift 2
        env HOME="$sb/home" PDHA_REPO_NAME="synthetic/repo" UNIFIED_DB_PATH="$DB" \
            SCANNER="$sb/fake_scan.sh" FAKE_MODE="$mode" FAKE_ROWS="$rows" \
            bash "$SELF" "$@" >"$sb/out" 2>"$sb/err"
        arc=$?
    }
    q() { duckdb -init /dev/null -csv -noheader "$DB" -c "$1" 2>&1; }

    # 1: no baseline yet -> INDETERMINATE (3), never findings, never clean
    run_audit findings "$R3"
    _expect_rc 3 "$arc" "scan with no baseline established is INDETERMINATE"
    _check "$("$GREP" -q -- '--baseline' "$sb/err" && echo 0 || echo 1)" "no-baseline message tells the operator to run --baseline"
    _check "$([ "$(q "SELECT count(*) FROM $TABLE")" = "0" ] && echo 0 || echo 1)" "indeterminate run wrote no finding rows"
    _check "$([ "$(q "SELECT status FROM housekeeping_runs WHERE task='private_data_history_audit' ORDER BY started_at DESC LIMIT 1")" = "partial" ] && echo 0 || echo 1)" "indeterminate run records heartbeat status 'partial'"

    # 2: baseline seeds all current findings as known, exit 0
    run_audit findings "$R3" --baseline
    _expect_rc 0 "$arc" "--baseline with findings present exits 0"
    _check "$([ "$(q "SELECT count(*) FROM $TABLE WHERE status='known'")" = "3" ] && echo 0 || echo 1)" "baseline recorded 3 findings, all status 'known'"
    _check "$("$GREP" -q 'findings=3 new=0 known=3 acknowledged=0' "$sb/out" && echo 0 || echo 1)" "baseline output reports findings=3 new=0 known=3 acknowledged=0"
    _check "$("$GREP" -qi 'baseline' "$sb/out" && echo 0 || echo 1)" "baseline run is loudly labelled"

    # 3: same findings again -> exit 0 (known), nothing listed as NEW
    run_audit findings "$R3"
    _expect_rc 0 "$arc" "run 2 with only known findings exits 0 (scanner itself exited 1)"
    _check "$("$GREP" -q 'findings=3 new=0 known=3 acknowledged=0' "$sb/out" && echo 0 || echo 1)" "run 2 output: findings=3 new=0 known=3 acknowledged=0"
    _check "$("$GREP" -q '^  NEW ' "$sb/out" && echo 1 || echo 0)" "run 2 lists no NEW finding"
    _check "$("$GREP" -q 'rule=uk-postcode src=generic count=1' "$sb/out" && echo 0 || echo 1)" "known findings are summarised by (rule, src, count)"
    _check "$("$GREP" -q 'docs/alpha.txt' "$sb/out" && echo 1 || echo 0)" "known findings are NOT listed individually"
    _check "$("$GREP" -q 'new=0 known=3 acknowledged=0 status=known_only' "$sb/home/.claude/logs/private_data_history_audit.log" && echo 0 || echo 1)" "log line carries findings/new/known/acknowledged and status=known_only"

    # 4: a newly introduced finding -> exit 1, listed in full, others not
    run_audit findings "$R4"
    _expect_rc 1 "$arc" "run 3 with one newly-introduced finding exits 1"
    _check "$("$GREP" -q 'findings=4 new=1 known=3 acknowledged=0' "$sb/out" && echo 0 || echo 1)" "run 3 output: findings=4 new=1 known=3 acknowledged=0"
    _check "$("$GREP" -q '^  NEW .*docs/delta.txt' "$sb/out" && echo 0 || echo 1)" "the NEW finding is listed in full"
    _check "$("$GREP" -q '^  NEW .*docs/alpha.txt' "$sb/out" && echo 1 || echo 0)" "a known finding is not listed as NEW"
    _check "$([ "$(q "SELECT rows_written FROM housekeeping_runs WHERE task='private_data_history_audit' AND status='ok' ORDER BY started_at DESC LIMIT 1")" = "1" ] && echo 0 || echo 1)" "heartbeat rows_written = NEW count (1)"
    NEWFP="$("$GREP" '^  NEW ' "$sb/out" | sed -n 's/.* fp=\([0-9a-f]*\).*/\1/p' | head -1)"
    _check "$([ "${#NEWFP}" -eq 16 ] && echo 0 || echo 1)" "NEW line prints a 16-hex fingerprint prefix"

    # 5: after being reported once, the finding is known -> exit 0 again
    run_audit findings "$R4"
    _expect_rc 0 "$arc" "run 4: previously-reported finding is now known, exits 0"
    _check "$("$GREP" -q 'findings=4 new=0 known=4 acknowledged=0' "$sb/out" && echo 0 || echo 1)" "run 4 output: findings=4 new=0 known=4"

    # 6: --ack by prefix; acknowledged is counted separately
    run_audit findings "$R4" --ack "$NEWFP"
    _expect_rc 0 "$arc" "--ack with a valid fingerprint prefix exits 0"
    _check "$([ "$(q "SELECT count(*) FROM $TABLE WHERE status='acknowledged'")" = "1" ] && echo 0 || echo 1)" "--ack set exactly one row to 'acknowledged'"
    run_audit findings "$R4"
    _expect_rc 0 "$arc" "run after --ack exits 0"
    _check "$("$GREP" -q 'findings=4 new=0 known=3 acknowledged=1' "$sb/out" && echo 0 || echo 1)" "output separates acknowledged=1 from known=3"
    printf '# comment\n%s extra\n\n' "$NEWFP" > "$sb/ackfile.txt"
    run_audit findings "$R4" --ack-file "$sb/ackfile.txt"
    _expect_rc 0 "$arc" "--ack-file (comments/blank lines tolerated) exits 0"

    # 7: ack / usage errors are exactly 2
    run_audit findings "$R4" --ack "0000000000000000"
    _expect_rc 2 "$arc" "--ack matching no finding is a usage error"
    run_audit findings "$R4" --ack "XYZ"
    _expect_rc 2 "$arc" "--ack with a malformed fingerprint is a usage error"
    run_audit findings "$R4" --ack "abcdef"
    _expect_rc 2 "$arc" "--ack with a too-short prefix is a usage error"
    run_audit findings "$R4" --ack
    _expect_rc 2 "$arc" "--ack with no value is a usage error"
    run_audit findings "$R4" --no-such-flag
    _expect_rc 2 "$arc" "unknown argument is a usage error"
    run_audit findings "$R4" --baseline --ack "$NEWFP"
    _expect_rc 2 "$arc" "--baseline together with --ack is a usage error"

    # 8: determinate clean run
    run_audit clean "$R4"
    _expect_rc 0 "$arc" "scanner clean + baseline present exits 0"
    _check "$("$GREP" -q 'findings=0 new=0 known=0 acknowledged=0' "$sb/out" && echo 0 || echo 1)" "clean output: findings=0 new=0 known=0 acknowledged=0"

    # 8b: private-repo shape (findings reported, scanner exits 0) is still diffed
    run_audit private_findings "$R4"
    _expect_rc 0 "$arc" "scanner exit 0 WITH a findings summary is treated as findings (all known) -> 0"
    _check "$("$GREP" -q 'findings=4 ' "$sb/out" && echo 0 || echo 1)" "private-repo shape: findings still counted (findings=4)"

    # 9: INDETERMINATE states must each be exactly 3 and must not touch the ledger
    before_rows="$(q "SELECT count(*) FROM $TABLE")"
    for m in crash blocked trunc usage mismatch silent0; do
        run_audit "$m" "$R4"
        _expect_rc 3 "$arc" "scanner state '$m' is INDETERMINATE"
    done
    _check "$([ "$(q "SELECT count(*) FROM $TABLE")" = "$before_rows" ] && echo 0 || echo 1)" "indeterminate runs left the ledger unchanged"
    _check "$("$GREP" -q 'status=indeterminate' "$sb/home/.claude/logs/private_data_history_audit.log" && echo 0 || echo 1)" "log records status=indeterminate (not findings_or_error)"
    _check "$("$GREP" -q 'findings_or_error' "$sb/home/.claude/logs/private_data_history_audit.log" && echo 1 || echo 0)" "the ambiguous 'findings_or_error' status is gone"

    env HOME="$sb/home" PDHA_REPO_NAME="synthetic/repo" UNIFIED_DB_PATH="$DB" \
        SCANNER="$sb/does_not_exist.sh" bash "$SELF" >"$sb/out" 2>"$sb/err"
    _expect_rc 3 "$?" "scanner binary missing is INDETERMINATE"
    env HOME="$sb/home" PDHA_REPO_NAME="synthetic/repo" UNIFIED_DB_PATH="$sb/no_such.duckdb" \
        SCANNER="$sb/fake_scan.sh" FAKE_MODE=findings FAKE_ROWS="$R4" bash "$SELF" >"$sb/out" 2>"$sb/err"
    _expect_rc 3 "$?" "findings DB missing is INDETERMINATE"
    # table missing: a DB with housekeeping_runs but no ledger
    duckdb -init /dev/null "$sb/notable.duckdb" -c "CREATE TABLE housekeeping_runs (id TEXT PRIMARY KEY, task TEXT NOT NULL, source_script TEXT NOT NULL, started_at TIMESTAMPTZ NOT NULL, ended_at TIMESTAMPTZ, status TEXT, rows_written INTEGER);" >/dev/null 2>&1
    env HOME="$sb/home" PDHA_REPO_NAME="synthetic/repo" UNIFIED_DB_PATH="$sb/notable.duckdb" \
        SCANNER="$sb/fake_scan.sh" FAKE_MODE=findings FAKE_ROWS="$R4" bash "$SELF" >"$sb/out" 2>"$sb/err"
    _expect_rc 3 "$?" "findings table missing is INDETERMINATE"
    # unwritable DB: a read-only copy
    cp "$DB" "$sb/ro.duckdb"
    chmod 444 "$sb/ro.duckdb"
    env HOME="$sb/home" PDHA_REPO_NAME="synthetic/repo" UNIFIED_DB_PATH="$sb/ro.duckdb" \
        SCANNER="$sb/fake_scan.sh" FAKE_MODE=findings FAKE_ROWS="$R4" bash "$SELF" >"$sb/out" 2>"$sb/err"
    _expect_rc 3 "$?" "read-only (unwritable) findings DB is INDETERMINATE"

    # 10: real scanner end to end on a SYNTHETIC repo: matched value never
    # leaks, and the binary-file rule works (generic skipped, deny-list kept).
    SENT="PDHASENT_k7Wz3_probe"
    rr="$sb/realrepo"
    mkdir -p "$rr"
    git -C "$rr" init -q
    git -C "$rr" config user.email t@example.com
    git -C "$rr" config user.name t
    # Root commit first: `git diff-tree` without --root lists nothing for a
    # root commit, so a file added there would not be scanned at all.
    printf 'readme\n' > "$rr/README.txt"
    git -C "$rr" add README.txt
    git -C "$rr" commit -q -m "root"
    # PII-shaped fixtures are assembled at runtime so this source file holds
    # no literal that the repo's own pre-commit scanner would flag.
    PC="SW1A"" 1AA"
    PH="+1415""5552671"
    printf 'postcode %s is here\n' "$PC" > "$rr/notes.txt"
    printf 'blob %s reach %s secret %s end\n' "$PC" "$PH" "$SENT" > "$rr/blob.rds"
    git -C "$rr" add notes.txt blob.rds
    git -C "$rr" commit -q -m "first"
    printf 'PRIV_PHONE=%s\n' "$SENT" > "$sb/pv.env"
    chmod 600 "$sb/pv.env"
    rdb="$sb/real.duckdb"
    duckdb -init /dev/null "$rdb" < "$SCHEMA_SQL" >/dev/null 2>&1
    run_real() {
        env HOME="$sb/home" PDHA_REPO_NAME="synthetic/real" UNIFIED_DB_PATH="$rdb" \
            SCANNER="$SCRIPT_DIR/private_data_scan.sh" REPO_ROOT="$rr" PRIVATE_VALUES_FILE="$sb/pv.env" \
            bash "$SELF" "$@" >"$sb/rout" 2>"$sb/rerr"
        arc=$?
    }
    run_real --baseline
    _expect_rc 0 "$arc" "real scanner on a synthetic repo: --baseline exits 0"
    rq() { duckdb -init /dev/null -csv -noheader "$rdb" -c "$1" 2>&1; }
    _check "$([ "$(rq "SELECT count(*) FROM $TABLE WHERE path LIKE '%blob.rds' AND src='generic'")" = "0" ] && echo 0 || echo 1)" "binary file: NO generic finding recorded for the .rds blob"
    _check "$([ "$(rq "SELECT count(*) FROM $TABLE WHERE path LIKE '%blob.rds' AND src='denylist'")" = "1" ] && echo 0 || echo 1)" "binary file: the deny-list finding IS still recorded for the .rds blob"
    _check "$([ "$(rq "SELECT count(*) FROM $TABLE WHERE path LIKE '%notes.txt' AND rule='uk-postcode'")" = "1" ] && echo 0 || echo 1)" "text file: generic finding recorded"
    _check "$("$GREP" -q 'findings=2 new=0 known=2' "$sb/rout" && echo 0 || echo 1)" "real baseline reports findings=2 (postcode in text + deny-list in .rds; .rds postcode/phone skipped)"
    printf 'call %s\n' "$PH" > "$rr/later.txt"
    git -C "$rr" add later.txt
    git -C "$rr" commit -q -m "later"
    run_real
    _expect_rc 1 "$arc" "real scanner: a newly committed leak is NEW -> exit 1"
    _check "$("$GREP" -q 'new=1 known=2' "$sb/rout" && echo 0 || echo 1)" "real scanner: new=1 known=2"
    run_real
    _expect_rc 0 "$arc" "real scanner: next run, nothing new -> exit 0"
    leak=0
    for f in "$sb/rout" "$sb/rerr" "$sb/home/.claude/logs/private_data_history_audit.log" "$sb/home/.claude/logs/private_data_scan.log"; do
        [ -f "$f" ] && "$GREP" -q -- "$SENT" "$f" && leak=1
    done
    rq "SELECT * FROM $TABLE" | "$GREP" -q -- "$SENT" && leak=1
    rq "SELECT * FROM private_data_scan_findings" | "$GREP" -q -- "$SENT" && leak=1
    _check "$([ "$leak" -eq 0 ] && echo 0 || echo 1)" "matched value never appears in stdout, stderr, either log, or the findings tables"
    _check "$([ "$(rq "SELECT count(*) FROM $TABLE")" -ge 3 ] && echo 0 || echo 1)" "leak check is not vacuous: the findings table holds rows"

    # -----------------------------------------------------------------------
    # 11: --all-public (llm#1367, llm#1372). Remotes are synthetic local repos
    # served over file:// ; `gh` is a stub that runs the script's REAL jq
    # filters over JSON fixtures (so a wrong filter is caught, not mocked away).
    # -----------------------------------------------------------------------
    ap="$sb/ap"
    mkdir -p "$ap/bin" "$ap/stub" "$ap/remotes/owner1" "$ap/remotes/forker" "$ap/gistremotes"
    adb="$sb/ap.duckdb"
    duckdb -init /dev/null "$adb" < "$SCHEMA_SQL" >/dev/null 2>&1
    SENT2="PDHAAP_m4Qx9_probe"
    printf 'PRIV_PHONE=%s\n' "$SENT2" > "$ap/pv.env"
    chmod 600 "$ap/pv.env"
    cat > "$ap/bin/gh" <<'EOF'
#!/usr/bin/env bash
ep=""; jqf="."
while [ $# -gt 0 ]; do
  case "$1" in
    --jq) jqf="$2"; shift ;;
    user|users/*|repos/*) ep="$1" ;;
  esac
  shift
done
if [ -n "${GH_STUB_FAIL:-}" ]; then
  case "$ep" in *"$GH_STUB_FAIL"*) echo "stub gh: HTTP 500 for $ep" >&2; exit 1 ;; esac
fi
case "$ep" in
  user) echo owner1 ;;
  users/*/repos*) jq -r "$jqf" < "$GH_STUB_DIR/repos.json" ;;
  users/*/gists*) jq -r "$jqf" < "$GH_STUB_DIR/gists.json" ;;
  repos/*/forks*)
    n="${ep#repos/}"; n="${n%%/forks*}"
    f="$GH_STUB_DIR/forks_$(printf '%s' "$n" | tr / _).json"
    if [ -f "$f" ]; then jq -r "$jqf" < "$f"; else echo '[]' | jq -r "$jqf"; fi ;;
  *) echo "stub gh: unexpected call: $ep" >&2; exit 1 ;;
esac
EOF
    chmod +x "$ap/bin/gh"
    mkrepo() {   # mkrepo DIR  -- synthetic repo with one root commit
        mkdir -p "$1"
        git -C "$1" init -q
        git -C "$1" config user.email t@example.com
        git -C "$1" config user.name t
        printf 'readme\n' > "$1/README.txt"
        git -C "$1" add README.txt
        git -C "$1" commit -q -m "root"
    }
    leak_commit() {   # leak_commit DIR FILE -- commit a deny-listed value
        printf 'secret %s end\n' "$SENT2" > "$1/$2"
        git -C "$1" add "$2"
        git -C "$1" commit -q -m "add $2"
    }
    mkrepo "$ap/remotes/owner1/a.git"
    mkrepo "$ap/remotes/owner1/b.git"
    mkrepo "$ap/remotes/owner1/priv.git"
    leak_commit "$ap/remotes/owner1/priv.git" leak.txt   # PRIVATE repo: must never be scanned
    git clone -q "$ap/remotes/owner1/a.git" "$ap/remotes/forker/a.git" 2>/dev/null
    mkrepo "$ap/gistremotes/abc123.git"
    set_repos() {   # set_repos NAME...  (public) ; owner1/priv is always private
        local first=1 out="["
        for n in "$@"; do [ "$first" -eq 1 ] || out="$out,"; first=0; out="$out{\"full_name\":\"$n\",\"private\":false}"; done
        printf '%s,{"full_name":"owner1/priv","private":true}]' "$out" > "$ap/stub/repos.json"
    }
    set_repos owner1/a owner1/b
    printf '[{"full_name":"forker/a","private":false},{"full_name":"forker/hidden","private":true}]' > "$ap/stub/forks_owner1_a.json"
    printf '[{"id":"abc123","public":true},{"id":"dead01","public":false}]' > "$ap/stub/gists.json"
    AP_X=()
    run_ap() {   # run_ap ARGS... ; env additions in AP_X ; sets $arc, $sb/aout, $sb/aerr
        env HOME="$sb/home" UNIFIED_DB_PATH="$adb" SCANNER="$SCRIPT_DIR/private_data_scan.sh" \
            PRIVATE_VALUES_FILE="$ap/pv.env" PDHA_EXTRA_PATH="$ap/bin" GH_STUB_DIR="$ap/stub" \
            PDHA_CACHE_DIR="$ap/cache" PDHA_CLONE_BASE="file://$ap/remotes" PDHA_GIST_BASE="file://$ap/gistremotes" \
            ${AP_X[@]+"${AP_X[@]}"} bash "$SELF" --all-public "$@" >"$sb/aout" 2>"$sb/aerr"
        arc=$?
    }
    aq() { duckdb -init /dev/null -csv -noheader "$adb" -c "$1" 2>&1; }
    LEDGER_FOR() { aq "SELECT count(*) FROM $TABLE WHERE repo='$1'"; }

    run_ap
    _expect_rc 3 "$arc" "all-public: no baseline for any repo is INDETERMINATE (not an alert flood, not clean)"
    _check "$("$GREP" -q 'repos=4 clean=0 new_findings=0 indeterminate=4' "$sb/aout" && echo 0 || echo 1)" "all-public: 4 units enumerated (2 repos + 1 public fork + 1 public gist), all INDETERMINATE"
    _check "$("$GREP" -qE 'owner1/priv|forker/hidden|dead01' "$sb/aout" "$sb/aerr" && echo 1 || echo 0)" "all-public: private repo, private fork and secret gist are never enumerated"
    _check "$([ "$(aq "SELECT count(*) FROM $TABLE")" = "0" ] && echo 0 || echo 1)" "all-public: indeterminate run wrote no ledger rows"

    run_ap --baseline
    _expect_rc 0 "$arc" "all-public --baseline on clean repos exits 0"
    _check "$("$GREP" -q 'repos=4 clean=4 new_findings=0 indeterminate=0' "$sb/aout" && echo 0 || echo 1)" "all-public --baseline: repos=4 clean=4"
    _check "$([ "$(aq "SELECT count(*) FROM housekeeping_runs WHERE task LIKE 'private_data_history_baseline:%' AND status='ok'")" = "4" ] && echo 0 || echo 1)" "all-public --baseline: one per-repo baseline marker per unit (clean repos have no ledger rows)"
    _check "$([ -d "$ap/cache/owner1__a.git" ] && [ -d "$ap/cache/gist__abc123.git" ] && echo 0 || echo 1)" "all-public: mirrors cached under the cache dir (repo and gist)"

    run_ap
    _expect_rc 0 "$arc" "all-public: two clean repos (+fork +gist) exit 0 (control for the planted-value case)"
    _check "$("$GREP" -q 'repos=4 clean=4 new_findings=0 indeterminate=0' "$sb/aout" && echo 0 || echo 1)" "all-public clean run: repos=4 clean=4 new_findings=0 indeterminate=0"

    leak_commit "$ap/remotes/owner1/b.git" leak.txt
    run_ap
    _expect_rc 1 "$arc" "all-public: a planted deny-listed value in ONE repo exits 1"
    _check "$("$GREP" -q 'repo=owner1/b outcome=FAIL' "$sb/aout" && echo 0 || echo 1)" "all-public: owner1/b flagged FAIL"
    _check "$([ "$("$GREP" -c 'outcome=PASS' "$sb/aout")" = "3" ] && echo 0 || echo 1)" "all-public: ONLY owner1/b flagged (other 3 units PASS)"
    _check "$("$GREP" -q 'repos=4 clean=3 new_findings=1 indeterminate=0' "$sb/aout" && echo 0 || echo 1)" "all-public summary: repos=4 clean=3 new_findings=1 indeterminate=0"
    _check "$([ "$(LEDGER_FOR owner1/b)" = "1" ] && [ "$(aq "SELECT count(*) FROM $TABLE")" = "1" ] && echo 0 || echo 1)" "all-public: ledger holds exactly 1 row, keyed by repo owner1/b"
    run_ap
    _expect_rc 0 "$arc" "all-public: the reported finding is known on the next run -> exit 0"

    # PR-ref-only commit: reachable from refs/pull/7/head and from NO branch.
    pa="$ap/remotes/owner1/a.git"
    br="$(git -C "$pa" symbolic-ref --short HEAD)"
    git -C "$pa" checkout -q -b tmp_pr
    leak_commit "$pa" prleak.txt
    prsha="$(git -C "$pa" rev-parse HEAD)"
    git -C "$pa" update-ref refs/pull/7/head "$prsha"
    git -C "$pa" checkout -q "$br"
    git -C "$pa" branch -q -D tmp_pr
    _check "$([ -z "$(git -C "$pa" branch --contains "$prsha" 2>/dev/null)" ] && echo 0 || echo 1)" "PR-ref test setup: the leaking commit is on no branch"
    # file:// (not a bare path): a local-path clone hardlinks the whole object
    # store and would contain the commit, making this control vacuous.
    git clone -q "file://$pa" "$sb/plainclone" 2>/dev/null
    _check "$(git -C "$sb/plainclone" cat-file -e "$prsha" 2>/dev/null && echo 1 || echo 0)" "PR-ref control: a plain (non-mirror) clone does NOT contain the commit"
    run_ap
    _expect_rc 1 "$arc" "all-public: a PR-ref-only leak is scanned (mirror includes refs/pull/*) -> exit 1"
    _check "$("$GREP" -q 'repo=owner1/a outcome=FAIL' "$sb/aout" && echo 0 || echo 1)" "all-public: owner1/a (leak only in refs/pull/7/head, cached mirror reused) flagged FAIL"

    # Gist: all revisions, repo = gist:<id>
    leak_commit "$ap/gistremotes/abc123.git" snippet.txt
    run_ap
    _expect_rc 1 "$arc" "all-public: a leak in a public gist exits 1"
    _check "$("$GREP" -q 'repo=gist:abc123 outcome=FAIL' "$sb/aout" && echo 0 || echo 1)" "all-public: gist flagged as gist:abc123"
    _check "$([ "$(LEDGER_FOR gist:abc123)" = "1" ] && echo 0 || echo 1)" "all-public: gist finding recorded in the ledger keyed gist:abc123"
    run_ap
    _expect_rc 0 "$arc" "all-public: after reporting, all known -> exit 0"

    # Unclonable repo is INDETERMINATE (3), never clean; no partial cache left.
    set_repos owner1/a owner1/b owner1/missing
    run_ap
    _expect_rc 3 "$arc" "all-public: an unclonable repo makes the run INDETERMINATE (exit 3)"
    _check "$("$GREP" -q 'repo=owner1/missing outcome=INDETERMINATE' "$sb/aout" && echo 0 || echo 1)" "all-public: owner1/missing reported INDETERMINATE"
    _check "$("$GREP" -q 'repos=5 clean=4 new_findings=0 indeterminate=1' "$sb/aout" && echo 0 || echo 1)" "all-public summary: repos=5 clean=4 new_findings=0 indeterminate=1"
    _check "$([ ! -e "$ap/cache/owner1__missing.git" ] && echo 0 || echo 1)" "all-public: a failed clone leaves no partial mirror behind"

    # A repo first seen without a baseline is INDETERMINATE for that repo only,
    # even though it holds a leak; --baseline then seeds it as known.
    mkrepo "$ap/remotes/owner1/c.git"
    leak_commit "$ap/remotes/owner1/c.git" leak.txt
    set_repos owner1/a owner1/b owner1/c
    run_ap
    _expect_rc 3 "$arc" "all-public: a new repo with no baseline is INDETERMINATE (not an alert flood)"
    _check "$("$GREP" -q 'repo=owner1/c outcome=INDETERMINATE' "$sb/aout" && echo 0 || echo 1)" "all-public: owner1/c INDETERMINATE (no per-repo baseline)"
    _check "$([ "$(LEDGER_FOR owner1/c)" = "0" ] && echo 0 || echo 1)" "all-public: the unbaselined repo wrote no ledger rows"
    run_ap --baseline
    _expect_rc 0 "$arc" "all-public --baseline seeds the new repo (exit 0)"
    _check "$([ "$(aq "SELECT count(*) FROM $TABLE WHERE repo='owner1/c' AND status='known'")" = "1" ] && echo 0 || echo 1)" "all-public --baseline: owner1/c finding recorded as known"
    run_ap
    _expect_rc 0 "$arc" "all-public: after seeding, owner1/c's finding is known -> exit 0"

    # Enumeration failures are INDETERMINATE, never a silently shorter audit.
    AP_X=(GH_STUB_FAIL=forks)
    run_ap
    _expect_rc 3 "$arc" "all-public: a failed forks listing is INDETERMINATE"
    _check "$("$GREP" -q 'repo=forks-of:owner1/a outcome=INDETERMINATE' "$sb/aout" && echo 0 || echo 1)" "all-public: the failed forks listing is named in the output"
    AP_X=(GH_STUB_FAIL=users/owner1/repos)
    run_ap
    _expect_rc 3 "$arc" "all-public: a failed repo listing is INDETERMINATE (exit 3, no partial audit)"
    AP_X=(GH_STUB_FAIL=gists)
    run_ap
    _expect_rc 3 "$arc" "all-public: a failed gist listing is INDETERMINATE"
    _check "$("$GREP" -q 'repo=gists-of:owner1 outcome=INDETERMINATE' "$sb/aout" && echo 0 || echo 1)" "all-public: the failed gist listing is named in the output"
    AP_X=()
    printf '[]' > "$ap/stub/repos.json"
    run_ap
    _expect_rc 3 "$arc" "all-public: an empty repository listing is INDETERMINATE, not 'nothing to audit'"
    set_repos owner1/a owner1/b owner1/c

    # Exit codes for the mode flag.
    run_ap --ack 0123456789abcdef
    _expect_rc 2 "$arc" "all-public together with --ack is a usage error"

    leak=0
    for f in "$sb/aout" "$sb/aerr" "$sb/home/.claude/logs/private_data_history_audit.log" "$sb/home/.claude/logs/private_data_scan.log"; do
        [ -f "$f" ] && "$GREP" -q -- "$SENT2" "$f" && leak=1
    done
    aq "SELECT * FROM $TABLE" | "$GREP" -q -- "$SENT2" && leak=1
    _check "$([ "$leak" -eq 0 ] && echo 0 || echo 1)" "all-public: matched value never appears in stdout, stderr, logs or the ledger"
    _check "$([ "$(aq "SELECT count(*) FROM $TABLE")" -ge 4 ] && echo 0 || echo 1)" "all-public leak check is not vacuous: ledger holds rows for b, a, gist, c"
    _check "$("$GREP" -q 'repo=owner1/b mode=' "$sb/home/.claude/logs/private_data_history_audit.log" && echo 0 || echo 1)" "all-public: per-repo log lines are tagged with the repo"

    echo ""
    echo "private_data_history_audit selftest: $pass/$total PASS"
    [ "$pass" -eq "$total" ] && exit 0
    exit 1
fi

# ---------------------------------------------------------------------------
# helpers shared by the real modes
# ---------------------------------------------------------------------------
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/pds_audit.XXXXXX")"
trap 'rm -rf "$TMPD"' EXIT

if [ "$BASELINE" -eq 1 ]; then MODE_LABEL="baseline"
elif [ "${#ACK_ARGS[@]}" -gt 0 ] || [ -n "$ACK_FILE" ]; then MODE_LABEL="ack"
elif [ "$APPLY" -eq 1 ]; then MODE_LABEL="apply"
else MODE_LABEL="dry-run"; fi

# indeterminate REASON -- exit 3, never reported as findings or clean
indeterminate() {
    echo "" >&2
    echo "private_data_history_audit: INDETERMINATE -- $1" >&2
    echo "New-vs-known could not be determined; this is NOT a clean result and NOT a findings result (exit 3)." >&2
    log_line "mode=${MODE_LABEL} status=indeterminate rc=3 reason=$(printf '%s' "$1" | tr '\t\n' '  ')"
    hk_run_end "partial" "0"
    exit 3
}

db_query() { duckdb -init /dev/null -bail -csv -noheader "$UNIFIED_DB" -c "$1" 2>"$TMPD/dberr"; }

require_db() {
    command -v duckdb >/dev/null 2>&1 || indeterminate "duckdb is not on PATH"
    [ -f "$UNIFIED_DB" ] || indeterminate "findings database not found (cannot record per-finding state)"
}

# ---------------------------------------------------------------------------
# --ack mode
# ---------------------------------------------------------------------------
if [ "$MODE_LABEL" = "ack" ]; then
    FPS=()
    if [ "${#ACK_ARGS[@]}" -gt 0 ]; then FPS=("${ACK_ARGS[@]}"); fi
    if [ -n "$ACK_FILE" ]; then
        if [ ! -r "$ACK_FILE" ]; then echo "private_data_history_audit: cannot read --ack-file $ACK_FILE" >&2; exit 2; fi
        while IFS= read -r line || [ -n "$line" ]; do
            line="${line%%#*}"
            tok=""
            read -r tok _ <<< "$line"
            [ -n "$tok" ] || continue
            FPS+=("$tok")
        done < "$ACK_FILE"
    fi
    if [ "${#FPS[@]}" -eq 0 ]; then echo "private_data_history_audit: no fingerprints to acknowledge" >&2; exit 2; fi
    for fp in "${FPS[@]}"; do
        if ! printf '%s' "$fp" | "$GREP" -qE '^[0-9a-f]{12,64}$'; then
            echo "private_data_history_audit: not a fingerprint (need 12-64 lowercase hex chars): $fp" >&2
            exit 2
        fi
    done
    require_db
    for fp in "${FPS[@]}"; do
        n="$(db_query "SELECT count(*) FROM ${TABLE} WHERE fingerprint LIKE '${fp}%'")" \
            || indeterminate "findings table unreadable ($(head -c 200 "$TMPD/dberr" | tr '\n' ' '))"
        if [ "$n" = "0" ]; then
            echo "private_data_history_audit: no finding matches fingerprint $fp" >&2
            exit 2
        fi
        if [ "$n" != "1" ]; then
            echo "private_data_history_audit: fingerprint prefix $fp is ambiguous ($n matches); use more characters" >&2
            exit 2
        fi
    done
    for fp in "${FPS[@]}"; do
        db_query "UPDATE ${TABLE} SET status = 'acknowledged' WHERE fingerprint LIKE '${fp}%'" >/dev/null \
            || indeterminate "could not write the acknowledgement ($(head -c 200 "$TMPD/dberr" | tr '\n' ' '))"
        echo "private_data_history_audit: acknowledged ${fp}"
    done
    log_line "mode=ack acknowledged_now=${#FPS[@]} status=acknowledged rc=0"
    exit 0
fi

# ---------------------------------------------------------------------------
# scan / baseline mode
# ---------------------------------------------------------------------------
[ "$MODE_LABEL" = "baseline" ] && HK_TASK="private_data_history_baseline"
hk_run_start

[ -x "$SCANNER" ] || indeterminate "scanner not found or not executable at $SCANNER"
require_db

# ---------------------------------------------------------------------------
# --all-public: every public repo of the owner, public forks of those repos and
# the owner's public gists (llm#1367, llm#1372). Each unit is scanned as a
# fresh GitHub MIRROR (all refs, including refs/pull/*) by re-invoking this
# script as a PDHA_CHILD, so the per-finding ledger, baseline and exact exit
# codes are the single-repo ones, keyed by owner/name (gists: gist:<id>).
# Per-unit outcome PASS / FAIL / INDETERMINATE; a unit that could not be
# enumerated, cloned or scanned is never clean.
# ---------------------------------------------------------------------------
if [ "$ALL_PUBLIC" -eq 1 ] && [ -z "$CHILD" ]; then
    SELF_PATH="$0"
    command -v git >/dev/null 2>&1 || indeterminate "git is not on PATH"
    command -v gh >/dev/null 2>&1 || indeterminate "gh is not on PATH (cannot enumerate public repositories)"
    CACHE_DIR="${PDHA_CACHE_DIR:-${HOME_DIR}/.cache/private_data_history_audit}"
    CLONE_BASE="${PDHA_CLONE_BASE:-https://github.com}"
    GIST_BASE="${PDHA_GIST_BASE:-https://gist.github.com}"
    mkdir -p "$CACHE_DIR" 2>/dev/null || indeterminate "cannot create the mirror cache directory $CACHE_DIR"
    export GIT_TERMINAL_PROMPT=0
    # Filters over the REST list payloads (also exercised by --selftest).
    JQ_REPOS='.[] | select(.private == false) | .full_name'
    JQ_GISTS='.[] | select(.public == true) | .id'
    RESULTS="$TMPD/results.tsv"; : > "$RESULTS"
    UNITS="$TMPD/units.tsv"; : > "$UNITS"          # name <TAB> url
    # add_result NAME OUTCOME FINDINGS NEW DETAIL
    add_result() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$RESULTS"; }

    OWNER="${PDHA_OWNER:-}"
    if [ -z "$OWNER" ]; then
        OWNER="$(gh api user --jq .login 2>"$TMPD/gh.err" </dev/null)" \
            || indeterminate "cannot determine the repository owner via gh ($(head -c 200 "$TMPD/gh.err" | tr '\n' ' '))"
    fi
    printf '%s' "$OWNER" | "$GREP" -qE '^[A-Za-z0-9-]+$' || indeterminate "owner login is not a plain GitHub login"

    # gh_list ENDPOINT JQ OUTFILE -> rc; output is one value per line
    gh_list() { gh api --paginate "$1" --jq "$2" >"$3" 2>"$TMPD/gh.err" </dev/null; }

    : > "$TMPD/repos.txt"
    if ! gh_list "users/${OWNER}/repos?type=owner&per_page=100" "$JQ_REPOS" "$TMPD/repos.txt"; then
        indeterminate "could not list the public repositories of ${OWNER} ($(head -c 200 "$TMPD/gh.err" | tr '\n' ' ')); refusing a partial audit"
    fi
    [ -s "$TMPD/repos.txt" ] || indeterminate "the repository listing for ${OWNER} was empty -- not trusted as 'no public repositories'"
    : > "$TMPD/forks.txt"
    while IFS= read -r r <&3 || [ -n "$r" ]; do
        [ -n "$r" ] || continue
        if printf '%s' "$r" | "$GREP" -qE '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; then
            if gh_list "repos/${r}/forks?per_page=100" "$JQ_REPOS" "$TMPD/f.one"; then
                cat "$TMPD/f.one" >> "$TMPD/forks.txt"
            else
                add_result "forks-of:${r}" INDETERMINATE 0 0 "could not list forks ($(head -c 120 "$TMPD/gh.err" | tr '\n' ' '))"
            fi
        fi
    done 3< "$TMPD/repos.txt"
    cat "$TMPD/repos.txt" "$TMPD/forks.txt" | sort -u > "$TMPD/all_repos.txt"
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        if printf '%s' "$r" | "$GREP" -qE '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; then
            printf '%s\t%s/%s.git\n' "$r" "$CLONE_BASE" "$r" >> "$UNITS"
        else
            add_result "invalid-repo-name" INDETERMINATE 0 0 "enumerated name is not a plain owner/name; not scanned"
        fi
    done < "$TMPD/all_repos.txt"

    : > "$TMPD/gists.txt"
    if gh_list "users/${OWNER}/gists?per_page=100" "$JQ_GISTS" "$TMPD/gists.txt"; then
        while IFS= read -r g; do
            [ -n "$g" ] || continue
            if printf '%s' "$g" | "$GREP" -qE '^[0-9a-fA-F]+$'; then
                printf 'gist:%s\t%s/%s.git\n' "$g" "$GIST_BASE" "$g" >> "$UNITS"
            else
                add_result "invalid-gist-id" INDETERMINATE 0 0 "enumerated gist id is not hex; not scanned"
            fi
        done < "$TMPD/gists.txt"
    else
        add_result "gists-of:${OWNER}" INDETERMINATE 0 0 "could not list public gists ($(head -c 120 "$TMPD/gh.err" | tr '\n' ' '))"
    fi

    CHILD_FLAGS=()
    [ "$BASELINE" -eq 1 ] && CHILD_FLAGS=(--baseline)
    echo "private_data_history_audit: --all-public owner=${OWNER} units=$(wc -l < "$UNITS" | tr -d ' ') (mode=${MODE_LABEL})"

    while IFS=$'\t' read -r uname uurl <&3; do
        [ -n "$uname" ] || continue
        udir="$CACHE_DIR/$(printf '%s' "$uname" | sed 's#[/:]#__#g').git"
        if [ -d "$udir" ]; then
            # Reuse the mirror: a failed update is NOT scanned (stale != fresh).
            if ! git -C "$udir" remote set-url origin "$uurl" </dev/null >"$TMPD/git.out" 2>&1 \
               || ! git -C "$udir" remote update --prune </dev/null >>"$TMPD/git.out" 2>&1; then
                add_result "$uname" INDETERMINATE 0 0 "mirror update failed ($(head -c 150 "$TMPD/git.out" | tr '\n' ' '))"
                continue
            fi
        else
            if ! git clone --quiet --mirror "$uurl" "$udir" </dev/null >"$TMPD/git.out" 2>&1; then
                rm -rf "$udir"   # our own partial clone, created a moment ago
                add_result "$uname" INDETERMINATE 0 0 "clone failed ($(head -c 150 "$TMPD/git.out" | tr '\n' ' '))"
                continue
            fi
        fi
        env PDHA_CHILD=1 PDHA_REPO_NAME="$uname" REPO_ROOT="$udir" PRIVATE_DATA_SCAN_VISIBILITY=public \
            SCANNER="$SCANNER" UNIFIED_DB_PATH="$UNIFIED_DB" \
            bash "$SELF_PATH" ${CHILD_FLAGS[@]+"${CHILD_FLAGS[@]}"} >"$TMPD/c.out" 2>"$TMPD/c.err" </dev/null
        crc=$?
        cnt="$("$GREP" -oE 'findings=[0-9]+ new=[0-9]+' "$TMPD/c.out" | head -1)"
        cf="${cnt#findings=}"; cf="${cf%% *}"; cn="${cnt##*new=}"
        case "$crc" in
            0)
                if [ -z "$cnt" ]; then
                    add_result "$uname" INDETERMINATE 0 0 "scan exited 0 without a findings summary"
                elif [ "$BASELINE" -eq 1 ]; then
                    add_result "$uname" BASELINED "$cf" 0 "baseline recorded"
                else
                    add_result "$uname" PASS "$cf" 0 ""
                fi ;;
            1)
                if [ -z "$cnt" ]; then
                    add_result "$uname" INDETERMINATE 0 0 "scan exited 1 without a findings summary"
                else
                    add_result "$uname" FAIL "$cf" "$cn" ""
                    "$GREP" '^  NEW ' "$TMPD/c.out" | sed "s#^#    [$uname] #" >> "$TMPD/all_new_lines.txt"
                fi ;;
            *)
                add_result "$uname" INDETERMINATE 0 0 "$("$GREP" -m1 'INDETERMINATE' "$TMPD/c.err" | head -c 220 | tr '\t\n' '  ')" ;;
        esac
    done 3< "$UNITS"

    N_UNITS="$(wc -l < "$RESULTS" | tr -d ' ')"
    N_CLEAN="$(awk -F'\t' '$2=="PASS"||$2=="BASELINED"' "$RESULTS" | wc -l | tr -d ' ')"
    N_INDET="$(awk -F'\t' '$2=="INDETERMINATE"' "$RESULTS" | wc -l | tr -d ' ')"
    N_NEWSUM="$(awk -F'\t' '$2=="FAIL"{s+=$4} END{print s+0}' "$RESULTS")"
    # Every enumerated unit must have exactly one outcome row (enumeration-level
    # failures add their own rows), otherwise a unit was silently dropped.
    N_ENUM="$(wc -l < "$UNITS" | tr -d ' ')"
    N_UNIT_ROWS="$(awk -F'\t' 'FNR==NR{u[$1]=1; next} ($1 in u)' "$UNITS" "$RESULTS" | wc -l | tr -d ' ')"
    if [ "$N_UNIT_ROWS" != "$N_ENUM" ]; then
        add_result "audit-bookkeeping" INDETERMINATE 0 0 "enumerated ${N_ENUM} unit(s) but recorded ${N_UNIT_ROWS} outcome(s)"
        N_UNITS=$((N_UNITS + 1)); N_INDET=$((N_INDET + 1))
    fi

    awk -F'\t' '{ printf "  repo=%s outcome=%s findings=%s new=%s%s\n", $1, $2, $3, $4, ($5 != "" ? "  # " $5 : "") }' "$RESULTS"
    if [ -s "$TMPD/all_new_lines.txt" ]; then
        echo "NEW findings -- triage these; acknowledge with: private_data_history_audit.sh --ack <fp>"
        cat "$TMPD/all_new_lines.txt"
    fi
    SUMMARY="repos=${N_UNITS} clean=${N_CLEAN} new_findings=${N_NEWSUM} indeterminate=${N_INDET}"
    echo "private_data_history_audit: ${SUMMARY}"

    if [ "$N_NEWSUM" -gt 0 ]; then
        log_line "mode=all-public ${SUMMARY} status=new_findings rc=1"
        hk_run_end "ok" "$N_NEWSUM"
        exit 1
    fi
    if [ "$N_INDET" -gt 0 ]; then
        echo "" >&2
        echo "private_data_history_audit: INDETERMINATE -- ${N_INDET} unit(s) could not be scanned; they are NOT clean (exit 3)." >&2
        log_line "mode=all-public ${SUMMARY} status=indeterminate rc=3"
        hk_run_end "partial" "0"
        exit 3
    fi
    log_line "mode=all-public ${SUMMARY} status=clean rc=0"
    hk_run_end "ok" "0"
    exit 0
fi

# Repo identity for the fingerprint: owner/name from the origin remote so the
# fingerprint is the same from any worktree or checkout of this repo.
REPO_NAME="${PDHA_REPO_NAME:-}"
if [ -z "$REPO_NAME" ]; then
    url="$(git -C "$SCRIPT_DIR" config --get remote.origin.url 2>/dev/null || true)"
    REPO_NAME="$(printf '%s' "$url" | sed -E 's#(\.git)?/?$##; s#^.*[:/]([^/:]+/[^/]+)$#\1#')"
    if [ -z "$REPO_NAME" ]; then
        REPO_NAME="$(basename "$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo unknown)")"
    fi
fi
REPO_SQL="$(sql_quote "$REPO_NAME")"

# Pre-flight: ledger readable/writable and baseline state, BEFORE the slow scan.
# --all-public child: baseline is PER REPO. A repo is baselined iff the ledger
# already holds a row for it or an ok per-repo marker run exists (a repo with
# no findings has no ledger rows, so it needs the marker). A repo seen for the
# first time without --baseline is INDETERMINATE, never an alert flood.
BASE_TASK="private_data_history_baseline"
if [ -n "$CHILD" ]; then
    BASE_TASK="private_data_history_baseline:${REPO_NAME}"
    state="$(db_query "SELECT (SELECT count(*) FROM ${TABLE} WHERE repo = '${REPO_SQL}'), (SELECT count(*) FROM housekeeping_runs WHERE task = '$(sql_quote "$BASE_TASK")' AND status = 'ok')")" \
        || indeterminate "findings database/table unusable -- apply the schema with housekeeping_schema_apply.sh ($(head -c 200 "$TMPD/dberr" | tr '\n' ' '))"
else
    state="$(db_query "SELECT (SELECT count(*) FROM ${TABLE}), (SELECT count(*) FROM housekeeping_runs WHERE task = 'private_data_history_baseline' AND status = 'ok')")" \
        || indeterminate "findings database/table unusable -- apply the schema with housekeeping_schema_apply.sh ($(head -c 200 "$TMPD/dberr" | tr '\n' ' '))"
fi
LEDGER_ROWS="${state%%,*}"
BASELINES="${state##*,}"
if [ "$MODE_LABEL" != "baseline" ] && [ "${LEDGER_ROWS:-0}" = "0" ] && [ "${BASELINES:-0}" = "0" ]; then
    if [ -n "$CHILD" ]; then
        indeterminate "no baseline established for this repo -- first scan needs: private_data_history_audit.sh --all-public --baseline"
    fi
    indeterminate "no baseline established -- the ledger is empty, so every finding would read as new. Run once: private_data_history_audit.sh --baseline"
fi

echo "private_data_history_audit: starting full-history scan (mode=${MODE_LABEL}; scan+report only, see header)"

"$SCANNER" --full-history --tsv >"$TMPD/scan.out" 2>"$TMPD/scan.err"
RC=$?
cat "$TMPD/scan.err" >&2

HDR="$("$GREP" -oE '^private-data-scan: [0-9]+ finding' "$TMPD/scan.out" | "$GREP" -oE '[0-9]+' | head -1)"
NROWS="$("$GREP" -c "^FINDING$(printf '\t')" "$TMPD/scan.out")"
NROWS="${NROWS:-0}"

case "$RC" in
    0|1)
        if [ -n "$HDR" ]; then
            [ "$HDR" = "$NROWS" ] || indeterminate "scanner announced $HDR finding(s) but delivered $NROWS row(s) (truncated or malformed output, scanner rc=$RC)"
        elif [ "$RC" -eq 0 ]; then
            "$GREP" -q '^private-data-scan: clean' "$TMPD/scan.out" \
                || indeterminate "scanner exited 0 without a clean or findings summary line"
        else
            indeterminate "scanner exited 1 without a findings summary (internal error, e.g. missing deny-list or failed self-check): $(head -c 200 "$TMPD/scan.err" | tr '\n' ' ')"
        fi
        ;;
    3) indeterminate "scanner reported INDETERMINATE (rc=3, e.g. truncated scan): $(head -c 200 "$TMPD/scan.err" | tr '\n' ' ')" ;;
    *) indeterminate "scanner exited with unexpected code rc=$RC" ;;
esac

# rows: src sev loc line rule (note dropped)
awk -F'\t' 'BEGIN{OFS="\t"} $1=="FINDING"{print $2,$3,$4,$5,$6}' "$TMPD/scan.out" > "$TMPD/rows.tsv"

if [ "$NROWS" -gt 0 ]; then
    STAGE_SRC="FROM read_csv('${TMPD}/rows.tsv', delim='\t', header=false, quote='', escape='', auto_detect=false,
        columns={'src':'VARCHAR','severity':'VARCHAR','loc':'VARCHAR','lnum':'VARCHAR','rule':'VARCHAR'})"
else
    STAGE_SRC="FROM (SELECT NULL::VARCHAR AS src, NULL::VARCHAR AS severity, NULL::VARCHAR AS loc, NULL::VARCHAR AS lnum, NULL::VARCHAR AS rule) WHERE false"
fi
NEW_STATUS="new"
[ "$MODE_LABEL" = "baseline" ] && NEW_STATUS="known"
CSVOPT="FORMAT csv, DELIMITER '\t', HEADER false, QUOTE '', ESCAPE ''"

cat > "$TMPD/apply.sql" <<SQL
BEGIN TRANSACTION;
CREATE TEMP TABLE stage AS
  SELECT DISTINCT
    sha256(concat_ws('|', '${REPO_SQL}', rule, src, loc, coalesce(lnum, ''))) AS fingerprint,
    src, severity, rule,
    split_part(loc, ':', 1) AS commit_sha,
    substr(loc, strpos(loc, ':') + 1) AS path,
    lnum AS line_num
  ${STAGE_SRC};
CREATE TEMP TABLE classified AS
  SELECT s.*, t.status AS old_status
  FROM stage s LEFT JOIN ${TABLE} t ON t.fingerprint = s.fingerprint;
COPY (SELECT fingerprint, severity, src, rule, commit_sha, path, line_num
      FROM classified WHERE old_status IS NULL ORDER BY rule, src, path, line_num)
  TO '${TMPD}/new.tsv' (${CSVOPT});
COPY (SELECT rule, src, count(*) FROM classified
      WHERE old_status IN ('new', 'known') GROUP BY rule, src ORDER BY rule, src)
  TO '${TMPD}/known.tsv' (${CSVOPT});
COPY (SELECT count(*) FILTER (WHERE old_status IS NULL),
             count(*) FILTER (WHERE old_status IN ('new', 'known')),
             count(*) FILTER (WHERE old_status = 'acknowledged'),
             count(*)
      FROM classified)
  TO '${TMPD}/counts.tsv' (${CSVOPT});
UPDATE ${TABLE}
  SET last_seen = current_timestamp,
      status = CASE WHEN status = 'new' THEN 'known' ELSE status END
  WHERE fingerprint IN (SELECT fingerprint FROM classified WHERE old_status IS NOT NULL);
INSERT INTO ${TABLE}
  (fingerprint, repo, rule, src, severity, commit_sha, path, line_num, first_seen, last_seen, status)
  SELECT fingerprint, '${REPO_SQL}', rule, src, severity, commit_sha, path, line_num,
         current_timestamp, current_timestamp, '${NEW_STATUS}'
  FROM classified WHERE old_status IS NULL;
COMMIT;
SQL

duckdb -init /dev/null -bail "$UNIFIED_DB" < "$TMPD/apply.sql" >"$TMPD/db.out" 2>"$TMPD/db.err" \
    || indeterminate "could not record per-finding state ($(head -c 200 "$TMPD/db.err" | tr '\n' ' '))"
[ -s "$TMPD/counts.tsv" ] || indeterminate "findings classification produced no counts"

IFS=$'\t' read -r N_NEW N_KNOWN N_ACK N_TOTAL < "$TMPD/counts.tsv"

if [ "$MODE_LABEL" = "baseline" ]; then
    echo "private_data_history_audit: findings=${N_TOTAL} new=0 known=$((N_KNOWN + N_NEW)) acknowledged=${N_ACK}"
    echo "private_data_history_audit: BASELINE -- ${N_NEW} previously-unseen finding(s) recorded as known; ${N_KNOWN} were already known. Future runs alert only on genuinely new fingerprints."
    if [ -n "$CHILD" ]; then
        # Per-repo baseline marker (a repo with no findings has no ledger rows).
        duckdb -init /dev/null -bail "$UNIFIED_DB" -c "
            INSERT INTO housekeeping_runs (id, task, source_script, started_at, ended_at, status, rows_written)
            VALUES (uuid()::VARCHAR, '$(sql_quote "$BASE_TASK")', '${SCRIPT_DIR}/private_data_history_audit.sh',
                    current_timestamp, current_timestamp, 'ok', 0);" >/dev/null 2>"$TMPD/db.err" \
            || indeterminate "could not record the per-repo baseline marker ($(head -c 200 "$TMPD/db.err" | tr '\n' ' '))"
    fi
    log_line "mode=baseline findings=${N_TOTAL} new=0 known=$((N_KNOWN + N_NEW)) acknowledged=${N_ACK} baselined_now=${N_NEW} status=baseline rc=0"
    hk_run_end "ok" "0"
    exit 0
fi

echo "private_data_history_audit: findings=${N_TOTAL} new=${N_NEW} known=${N_KNOWN} acknowledged=${N_ACK}"
if [ "$N_NEW" -gt 0 ]; then
    echo "NEW findings (${N_NEW}) -- triage these; acknowledge with: private_data_history_audit.sh --ack <fp>"
    while IFS=$'\t' read -r fp sev src rule csha path lnum; do
        [ -n "$fp" ] || continue
        printf '  NEW [%s] src=%s rule=%s fp=%s %s:%s:%s\n' "$sev" "$src" "$rule" "${fp:0:16}" "$csha" "$path" "$lnum"
    done < "$TMPD/new.tsv"
fi
if [ -s "$TMPD/known.tsv" ]; then
    echo "Known findings (not re-listed), by rule:"
    while IFS=$'\t' read -r rule src cnt; do
        [ -n "$rule" ] || continue
        printf '  known: rule=%s src=%s count=%s\n' "$rule" "$src" "$cnt"
    done < "$TMPD/known.tsv"
fi

if [ "$N_NEW" -gt 0 ]; then
    echo "" >&2
    echo "private_data_history_audit: ${N_NEW} NEW finding(s) (exit 1). This does NOT auto-remediate -- see" >&2
    echo ".claude/rules/repo-visibility-gate.md's 'The audit itself' section for remediation options" >&2
    echo "(orphan-squash / git filter-repo / accept and keep private). Review the NEW findings above." >&2
    log_line "mode=${MODE_LABEL} findings=${N_TOTAL} new=${N_NEW} known=${N_KNOWN} acknowledged=${N_ACK} status=new_findings rc=1"
    hk_run_end "ok" "$N_NEW"
    exit 1
fi

if [ "$N_TOTAL" -gt 0 ]; then ST="known_only"; else ST="clean"; fi
log_line "mode=${MODE_LABEL} findings=${N_TOTAL} new=0 known=${N_KNOWN} acknowledged=${N_ACK} status=${ST} rc=0"
hk_run_end "ok" "0"
exit 0
