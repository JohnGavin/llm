#!/usr/bin/env bash
# disk_headroom_check.sh -- read-only disk headroom sampler and check (llm#1421)
#
# Hourly Time Machine local snapshots pinned ~36 GiB of the Data volume. This
# script (1) samples free space, snapshot list and candidate-file size/mtime
# into a TSV so churn can be measured, and (2) warns when free space is low.
# It never uses sudo, never walks the disk, and never opens a DuckDB/sqlite
# file (stat only). It does not act on what it measures.
#
# Usage:
#   disk_headroom_check.sh --sample
#   disk_headroom_check.sh --check [--min-free-gib N]     (default N=40)
#   disk_headroom_check.sh --report
#   disk_headroom_check.sh --selftest
#
# Exit codes (exit-code-conventions): 0 ok, 1 problem (low space), 2 usage,
# 3 INDETERMINATE (df unparseable / volume missing / too few samples).
#
# Environment:
#   DISK_HEADROOM_LOG_DIR     TSV directory (default $HOME/.claude/logs)
#   DISK_HEADROOM_VOLUME      volume to measure (default /System/Volumes/Data)
#   DISK_HEADROOM_FILES       colon-separated candidate files (default: unified
#                             DuckDB, roborev reviews.db, codex state_5.sqlite)
#   DISK_HEADROOM_MIN_SAMPLES samples required by --report (default 6)
#   DISK_HEADROOM_AUTO_REPORT_AT  samples after which --sample writes the report
#                             itself (default 48)
#
# Automation (no human needed; the launchd plist only calls --sample): after a
# successful --sample row, if the TSV holds >= DISK_HEADROOM_AUTO_REPORT_AT
# samples and the report is missing or older than 24 h, the --report output is
# written to $LOG_DIR/disk_headroom_report.txt (temp file, then mv). A macOS
# notification (osascript) is sent only when that report is produced for the
# first time, or when free space is below 40 GiB and none was sent in the last
# 24 h (marker: $LOG_DIR/disk_headroom_lowspace.notified). Report and
# notification errors go to stderr and never change --sample's exit status.
# Report-ready notice is retried each sample until osascript succeeds
# (marker: $LOG_DIR/disk_headroom_report.notified, written only on success).
# Output files: disk_headroom_report.txt, disk_headroom_report.notified,
# disk_headroom_lowspace.notified.

set -uo pipefail

VOLUME="${DISK_HEADROOM_VOLUME:-/System/Volumes/Data}"
LOG_DIR="${DISK_HEADROOM_LOG_DIR:-$HOME/.claude/logs}"
TSV="$LOG_DIR/disk_headroom.tsv"
DEFAULT_FILES="$HOME/.claude/logs/unified.duckdb:$HOME/.roborev/reviews.db:$HOME/.codex/state_5.sqlite"
FILES="${DISK_HEADROOM_FILES:-$DEFAULT_FILES}"
MIN_SAMPLES="${DISK_HEADROOM_MIN_SAMPLES:-6}"
SELF="${BASH_SOURCE[0]}"

usage() {
    cat >&2 <<'EOF'
usage: disk_headroom_check.sh --sample | --check [--min-free-gib N] | --report | --selftest
EOF
}

# Prints "used_kb avail_kb" for the volume; returns 3 if it cannot be parsed.
read_df() {
    local out line used avail
    if ! out="$(df -k "$VOLUME" 2>/dev/null)"; then
        return 3
    fi
    line="$(printf '%s\n' "$out" | awk 'NR>1 {l=$0} END {print l}')"
    # fields: fs 1024-blocks used avail ...
    used="$(printf '%s\n' "$line" | awk '{print $3}')"
    avail="$(printf '%s\n' "$line" | awk '{print $4}')"
    case "$used" in ''|*[!0-9]*) return 3 ;; esac
    case "$avail" in ''|*[!0-9]*) return 3 ;; esac
    printf '%s %s\n' "$used" "$avail"
}

# Prints "size mtime" for a file (stat only), or "-1 -1" when absent.
stat_file() {
    local f="$1" out
    if [ ! -e "$f" ]; then
        echo "-1 -1"
        return 0
    fi
    out="$(stat -c '%s %Y' "$f" 2>/dev/null)" || out="$(stat -f '%z %m' "$f" 2>/dev/null)" || out=""
    case "$out" in
        *[!0-9\ ]*|'') echo "-1 -1" ;;
        *) echo "$out" ;;
    esac
}

do_sample() {
    local dfout used_kb avail_kb snaps snap_count snap_names files_col f st ts
    if ! dfout="$(read_df)"; then
        echo "sample:INDETERMINATE df unparseable for $VOLUME"
        return 3
    fi
    used_kb="${dfout% *}"
    avail_kb="${dfout#* }"
    if snaps="$(tmutil listlocalsnapshots / 2>/dev/null)"; then
        snaps="$(printf '%s\n' "$snaps" | grep '^com\.apple\.TimeMachine\.' || true)"
        if [ -z "$snaps" ]; then
            snap_count=0
            snap_names="-"
        else
            snap_count="$(printf '%s\n' "$snaps" | wc -l | tr -d ' ')"
            snap_names="$(printf '%s\n' "$snaps" | sed 's/^com\.apple\.TimeMachine\.//; s/\.local$//' | paste -sd, -)"
        fi
    else
        snap_count="NA"
        snap_names="NA"
    fi
    files_col=""
    local IFS_SAVE="$IFS"
    IFS=':'
    for f in $FILES; do
        [ -n "$f" ] || continue
        st="$(stat_file "$f")"
        files_col="${files_col:+$files_col;}${f}|${st% *}|${st#* }"
    done
    IFS="$IFS_SAVE"
    mkdir -p "$LOG_DIR" 2>/dev/null || { echo "sample:INDETERMINATE cannot create $LOG_DIR"; return 3; }
    if [ ! -s "$TSV" ]; then
        printf 'ts\tused_bytes\tavail_bytes\tsnap_count\tsnap_names\tfiles\n' >> "$TSV" || return 3
    fi
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$((used_kb * 1024))" "$((avail_kb * 1024))" \
        "$snap_count" "$snap_names" "$files_col" >> "$TSV" || return 3
    echo "sample:ok $ts avail_gib=$((avail_kb / 1048576)) snapshots=$snap_count"
    # Automation: never affects the sample's own exit status.
    auto_report "$avail_kb" "$snap_count" || echo "auto-report: failed (ignored)" >&2
    return 0
}

# Best-effort macOS notification; failure is logged, never fatal. Returns
# osascript's status so callers can decide whether to set a marker.
notify() {
    local msg="$1"
    osascript -e "display notification \"$msg\" with title \"Disk headroom\"" >/dev/null 2>&1 && return 0
    echo "auto-report: notification failed (ignored)" >&2
    return 1
}

# After a successful sample: write the 48h report once enough samples exist
# (at most every 24 h) and notify on first report or low free space.
auto_report() {
    local avail_kb="$1" snaps="$2" at n report existed=0 tmpf free_gib marker rmarker
    at="${DISK_HEADROOM_AUTO_REPORT_AT:-48}"
    case "$at" in ''|*[!0-9]*) echo "auto-report: bad DISK_HEADROOM_AUTO_REPORT_AT, using 48" >&2; at=48 ;; esac
    report="$LOG_DIR/disk_headroom_report.txt"
    marker="$LOG_DIR/disk_headroom_lowspace.notified"
    rmarker="$LOG_DIR/disk_headroom_report.notified"
    free_gib=$((avail_kb / 1048576))
    n="$(awk -F'\t' 'NR>1 && NF>=6' "$TSV" | wc -l | tr -d ' ')"
    if [ "$n" -ge "$at" ]; then
        [ -e "$report" ] && existed=1
        if [ "$existed" -eq 0 ] || [ -n "$(find "$report" -mmin +1440 2>/dev/null)" ]; then
            if tmpf="$(mktemp "$LOG_DIR/.disk_headroom_report.XXXXXX" 2>/dev/null)"; then
                if do_report > "$tmpf" 2>&1 && mv "$tmpf" "$report"; then
                    :
                else
                    echo "auto-report: report generation failed: $(cat "$tmpf" 2>/dev/null)" >&2
                    rm -f "$tmpf"
                fi
            else
                echo "auto-report: cannot create temp file in $LOG_DIR" >&2
            fi
        fi
    fi
    # Report-ready notification: retried every sample until notify succeeds,
    # then the marker (written only on success) stops it.
    if [ -s "$report" ] && [ ! -e "$rmarker" ]; then
        if notify "Report ready: free ${free_gib} GiB, ${snaps} snapshots. See $report"; then
            : > "$rmarker"
        fi
    fi
    if [ "$avail_kb" -lt $((40 * 1048576)) ]; then
        if [ ! -e "$marker" ] || [ -n "$(find "$marker" -mmin +1440 2>/dev/null)" ]; then
            local lowmsg="Low disk: free ${free_gib} GiB (< 40), ${snaps} snapshots."
            if [ -s "$report" ]; then lowmsg="$lowmsg Report: $report"; else lowmsg="$lowmsg Report not yet available."; fi
            if notify "$lowmsg"; then
                : > "$marker"
            fi
        fi
    fi
    return 0
}

do_check() {
    local min=40 dfout avail_kb free_gib
    while [ $# -gt 0 ]; do
        case "$1" in
            --min-free-gib)
                [ $# -ge 2 ] || { usage; return 2; }
                min="$2"
                shift 2 ;;
            *) usage; return 2 ;;
        esac
    done
    case "$min" in ''|*[!0-9]*) usage; return 2 ;; esac
    if ! dfout="$(read_df)"; then
        echo "disk:INDETERMINATE df unparseable or volume missing ($VOLUME)"
        return 3
    fi
    avail_kb="${dfout#* }"
    free_gib=$((avail_kb / 1048576))
    if [ "$avail_kb" -lt $((min * 1048576)) ]; then
        echo "disk:LOW free=${free_gib} GiB (< ${min}): thin snapshots with: sudo tmutil thinlocalsnapshots / 30000000000 4"
        return 1
    fi
    echo "disk:ok free=${free_gib} GiB"
    return 0
}

do_report() {
    local n
    if [ ! -f "$TSV" ]; then
        echo "report:INDETERMINATE (0 samples)"
        return 3
    fi
    n="$(awk -F'\t' 'NR>1 && NF>=6' "$TSV" | wc -l | tr -d ' ')"
    if [ "$n" -lt "$MIN_SAMPLES" ]; then
        echo "report:INDETERMINATE ($n samples)"
        return 3
    fi
    awk -F'\t' -v n="$n" '
        NR==1 { next }
        NF<6 { next }
        {
            if (!seen++) { first_ts=$1; first_avail=$3 }
            last_ts=$1; last_avail=$3
            m = split($6, ent, ";")
            for (i = 1; i <= m; i++) {
                split(ent[i], p, "|")
                path = p[1]
                if (!(path in known)) { known[path]=1; order[++np]=path }
                if ((path in lastm) && lastm[path] != p[3]) changes[path]++
                lastm[path] = p[3]; size[path] = p[2]
            }
        }
        END {
            printf "report: %d samples, %s .. %s\n", n, first_ts, last_ts
            printf "free-space delta: %.2f GiB (first %.2f -> last %.2f)\n", \
                (last_avail-first_avail)/1073741824, first_avail/1073741824, last_avail/1073741824
            printf "%-10s %-12s %s\n", "mtime-chg", "size_MiB", "file"
            for (i = 1; i <= np; i++) {
                pth = order[i]
                if (size[pth] < 0) printf "%-10s %-12s %s (absent)\n", "-", "-", pth
                else printf "%-10d %-12.1f %s\n", changes[pth]+0, size[pth]/1048576, pth
            }
        }' "$TSV"
    return 0
}

# --------------------------------------------------------------------------
# Selftest: stub df/tmutil on PATH, temp dirs only. Asserts exact exit codes.
# --------------------------------------------------------------------------
do_selftest() {
    local tmp shim pass=0 fail=0 rc out
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/disk_headroom_selftest.XXXXXX")" || return 3
    shim="$tmp/shim"
    mkdir -p "$shim" "$tmp/logs"
    # Stub df: STUB_DF_MODE = ok | garbage | fail ; STUB_DF_AVAIL_KB sets Avail
    cat > "$shim/df" <<'EOF'
#!/bin/sh
case "${STUB_DF_MODE:-ok}" in
  ok)
    echo "Filesystem 1024-blocks Used Available Capacity iused ifree %iused Mounted on"
    echo "/dev/stub 971350180 700000000 ${STUB_DF_AVAIL_KB:-100000000} 88% 1 1 1% /System/Volumes/Data" ;;
  garbage) echo "total nonsense"; echo "not a df line" ;;
  fail) exit 1 ;;
esac
EOF
    cat > "$shim/tmutil" <<'EOF'
#!/bin/sh
echo "Snapshots for disk /:"
echo "com.apple.TimeMachine.2026-10-13-104400.local"
echo "com.apple.TimeMachine.2026-10-13-114400.local"
EOF
    cat > "$shim/osascript" <<'EOF'
#!/bin/sh
echo "$*" >> "$OSA_LOG"
[ -z "${STUB_OSA_FAIL:-}" ] || exit 1
EOF
    chmod +x "$shim/df" "$shim/tmutil" "$shim/osascript"
    printf 'aaaa' > "$tmp/a.db"
    printf 'bbbbbbbb' > "$tmp/b.db"

    run() { # run <args...>; sets rc and out; env passed via caller
        out="$(PATH="$shim:$PATH" DISK_HEADROOM_LOG_DIR="${LOGD:-$tmp/logs}" OSA_LOG="$tmp/osa.log" \
            DISK_HEADROOM_FILES="$tmp/a.db:$tmp/b.db:$tmp/missing.db" \
            bash "$SELF" "$@" 2>&1)"
        rc=$?
    }
    expect() { # expect <label> <want_rc> [grep-pattern]
        local label="$1" want="$2" pat="${3:-}"
        if [ "$rc" -eq "$want" ] && { [ -z "$pat" ] || printf '%s' "$out" | grep -q -- "$pat"; }; then
            pass=$((pass + 1)); echo "PASS: $label (rc=$rc)"
        else
            fail=$((fail + 1)); echo "FAIL: $label (rc=$rc want=$want pat='$pat') out: $out"
        fi
    }
    notcontains() { # notcontains <label> <pattern>
        if printf '%s' "$out" | grep -q -- "$2"; then
            fail=$((fail + 1)); echo "FAIL: $1 (output contains '$2'): $out"
        else
            pass=$((pass + 1)); echo "PASS: $1"
        fi
    }

    # --check
    STUB_DF_AVAIL_KB=100000000 run --check;                         expect "check ok (95 GiB free)" 0 '^disk:ok free=95 GiB'
    STUB_DF_AVAIL_KB=10000000 run --check;                          expect "check low (9 GiB free)" 1 '^disk:LOW free=9 GiB (< 40): thin snapshots with: sudo tmutil thinlocalsnapshots / 30000000000 4'
    STUB_DF_AVAIL_KB=10000000 run --check --min-free-gib 5;         expect "check ok at custom threshold" 0 '^disk:ok'
    STUB_DF_AVAIL_KB=100000000 run --check --min-free-gib 200;      expect "check low at custom threshold" 1 '^disk:LOW'
    STUB_DF_MODE=garbage run --check;                               expect "check garbage df -> INDETERMINATE" 3 '^disk:INDETERMINATE'
    notcontains "garbage df never prints ok" 'disk:ok'
    STUB_DF_MODE=fail run --check;                                  expect "check failing df -> INDETERMINATE" 3 '^disk:INDETERMINATE'
    run --check --min-free-gib abc;                                 expect "check non-integer threshold -> usage" 2
    run --check --bogus;                                            expect "check unknown option -> usage" 2
    run --check --min-free-gib;                                     expect "check missing threshold value -> usage" 2
    run;                                                            expect "no args -> usage" 2
    run --nonsense;                                                 expect "unknown mode -> usage" 2

    # --report before any sample
    run --report;                                                   expect "report with no TSV -> INDETERMINATE" 3 'report:INDETERMINATE (0 samples)'

    # --sample
    STUB_DF_MODE=garbage run --sample;                              expect "sample garbage df -> INDETERMINATE" 3 'sample:INDETERMINATE'
    if [ -e "$tmp/logs/disk_headroom.tsv" ]; then
        fail=$((fail + 1)); echo "FAIL: indeterminate sample must not write a row"
    else
        pass=$((pass + 1)); echo "PASS: indeterminate sample wrote no row"
    fi
    STUB_DF_AVAIL_KB=100000000 run --sample;                        expect "sample ok" 0 'sample:ok .* snapshots=2'
    local rows
    rows="$(wc -l < "$tmp/logs/disk_headroom.tsv" | tr -d ' ')"
    if [ "$rows" = "2" ]; then pass=$((pass + 1)); echo "PASS: header + 1 row"; else fail=$((fail + 1)); echo "FAIL: expected 2 lines, got $rows"; fi
    if grep -q "2026-10-13-104400,2026-10-13-114400" "$tmp/logs/disk_headroom.tsv" && grep -q "missing.db|-1|-1" "$tmp/logs/disk_headroom.tsv" && grep -q "a.db|4|" "$tmp/logs/disk_headroom.tsv"; then
        pass=$((pass + 1)); echo "PASS: row has snapshot names, absent file, file size"
    else
        fail=$((fail + 1)); echo "FAIL: row content: $(cat "$tmp/logs/disk_headroom.tsv")"
    fi

    # --report with too few samples (1 < 6)
    run --report;                                                   expect "report with 1 sample -> INDETERMINATE" 3 'report:INDETERMINATE (1 samples)'

    # 6 samples total, mtime of a.db changes in 2 of the gaps, b.db never.
    local i
    for i in 1 2 3 4 5; do
        if [ "$i" -eq 2 ] || [ "$i" -eq 4 ]; then touch -t "202601010000.0${i}" "$tmp/a.db"; fi
        STUB_DF_AVAIL_KB=$((100000000 - i * 1048576)) run --sample
    done
    run --report;                                                   expect "report with 6 samples" 0 'report: 6 samples'
    if printf '%s\n' "$out" | grep -E '^2 +0\.0 .*a\.db$' >/dev/null && printf '%s\n' "$out" | grep -E '^0 +0\.0 .*b\.db$' >/dev/null && printf '%s\n' "$out" | grep -q 'missing.db (absent)' && printf '%s\n' "$out" | grep -q 'free-space delta: -5.00 GiB'; then
        pass=$((pass + 1)); echo "PASS: report churn counts (a.db=2, b.db=0), absent file, delta -5.00 GiB"
    else
        fail=$((fail + 1)); echo "FAIL: report content: $out"
    fi

    # --- auto-report + notification (llm#1421), separate log dir, osascript stub
    local L2="$tmp/l2" osa="$tmp/osa.log" rep n_osa
    mkdir -p "$L2"
    rep="$L2/disk_headroom_report.txt"
    osa_count() { if [ -f "$osa" ]; then wc -l < "$osa" | tr -d ' '; else echo 0; fi; }
    check_eq() { # check_eq <label> <got> <want>
        if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "PASS: $1"; else fail=$((fail + 1)); echo "FAIL: $1 (got '$2' want '$3')"; fi
    }
    # 46 synthetic rows, so the next sample is the 47th.
    printf 'ts\tused_bytes\tavail_bytes\tsnap_count\tsnap_names\tfiles\n' > "$L2/disk_headroom.tsv"
    for i in $(seq 1 46); do
        printf '2026-01-01T00:%02d:00Z\t1\t100000000000\t2\tx\t%s|4|%d\n' "$((i % 60))" "$tmp/a.db" "$i" >> "$L2/disk_headroom.tsv"
    done

    LOGD="$L2" STUB_DF_AVAIL_KB=100000000 run --sample;             expect "auto: 47th sample ok" 0 'sample:ok'
    if [ -e "$rep" ]; then fail=$((fail + 1)); echo "FAIL: 47 samples must not produce a report"; else pass=$((pass + 1)); echo "PASS: 47 samples -> no report"; fi
    check_eq "auto: 47 samples -> no notification" "$(osa_count)" 0

    LOGD="$L2" STUB_DF_AVAIL_KB=100000000 run --sample;             expect "auto: 48th sample ok" 0 'sample:ok'
    if [ -s "$rep" ] && grep -q 'report: 48 samples' "$rep"; then pass=$((pass + 1)); echo "PASS: 48 samples -> report written"; else fail=$((fail + 1)); echo "FAIL: 48th sample must write report; got: $(cat "$rep" 2>/dev/null)"; fi
    check_eq "auto: first report -> exactly 1 notification" "$(osa_count)" 1
    if grep -q 'snapshot' "$osa" && grep -q "$rep" "$osa" && grep -q 'GiB' "$osa"; then pass=$((pass + 1)); echo "PASS: notification states GiB, snapshots, report path"; else fail=$((fail + 1)); echo "FAIL: notification text: $(cat "$osa" 2>/dev/null)"; fi

    printf 'SENTINEL\n' > "$rep"
    LOGD="$L2" STUB_DF_AVAIL_KB=100000000 run --sample;             expect "auto: 49th sample ok" 0 'sample:ok'
    check_eq "auto: young report not rewritten" "$(cat "$rep")" SENTINEL
    check_eq "auto: no repeat notification, free space fine" "$(osa_count)" 1

    touch -t 202601010000 "$rep"
    LOGD="$L2" STUB_DF_AVAIL_KB=100000000 run --sample;             expect "auto: 50th sample ok" 0 'sample:ok'
    if grep -q 'report: 50 samples' "$rep"; then pass=$((pass + 1)); echo "PASS: stale report rewritten"; else fail=$((fail + 1)); echo "FAIL: stale report not rewritten: $(cat "$rep")"; fi
    check_eq "auto: rewrite of existing report -> no notification" "$(osa_count)" 1

    LOGD="$L2" STUB_DF_AVAIL_KB=10000000 run --sample;              expect "auto: low-space sample ok" 0 'sample:ok'
    check_eq "auto: low space -> 1 more notification" "$(osa_count)" 2
    if [ -e "$L2/disk_headroom_lowspace.notified" ]; then pass=$((pass + 1)); echo "PASS: low-space marker written"; else fail=$((fail + 1)); echo "FAIL: low-space marker missing"; fi
    LOGD="$L2" STUB_DF_AVAIL_KB=10000000 run --sample;              expect "auto: low-space repeat sample ok" 0 'sample:ok'
    check_eq "auto: low space within 24h -> no repeat" "$(osa_count)" 2
    touch -t 202601010000 "$L2/disk_headroom_lowspace.notified"
    LOGD="$L2" STUB_DF_AVAIL_KB=10000000 run --sample;              expect "auto: low-space after 24h sample ok" 0 'sample:ok'
    check_eq "auto: low space after 24h -> notified again" "$(osa_count)" 3

    # low-space message with a report present carries the report path
    if tail -n 1 "$osa" | grep -q "Report: $rep"; then pass=$((pass + 1)); echo "PASS: low-space message cites existing report"; else fail=$((fail + 1)); echo "FAIL: low-space message lacks report path: $(tail -n 1 "$osa")"; fi

    # osascript failure never changes exit status, and the first-report
    # notification is retried on later samples until it succeeds (marker).
    rm -f "$rep" "$L2/disk_headroom_lowspace.notified" "$L2/disk_headroom_report.notified"
    n_osa="$(osa_count)"
    LOGD="$L2" STUB_OSA_FAIL=1 STUB_DF_AVAIL_KB=100000000 run --sample; expect "auto: failing osascript keeps exit 0" 0 'sample:ok'
    if [ -s "$rep" ] && [ ! -e "$L2/disk_headroom_report.notified" ]; then pass=$((pass + 1)); echo "PASS: failed notify leaves no report marker"; else fail=$((fail + 1)); echo "FAIL: failed notify must leave no marker"; fi
    n_osa="$(osa_count)"
    LOGD="$L2" STUB_DF_AVAIL_KB=100000000 run --sample;             expect "auto: retry sample ok" 0 'sample:ok'
    check_eq "auto: retry notifies exactly once" "$(( $(osa_count) - n_osa ))" 1
    if [ -e "$L2/disk_headroom_report.notified" ]; then pass=$((pass + 1)); echo "PASS: report marker written after successful notify"; else fail=$((fail + 1)); echo "FAIL: report marker missing after successful notify"; fi
    n_osa="$(osa_count)"
    LOGD="$L2" STUB_DF_AVAIL_KB=100000000 run --sample;             expect "auto: further sample ok" 0 'sample:ok'
    check_eq "auto: no further report notification" "$(( $(osa_count) - n_osa ))" 0

    # low-space message without a report must not cite a report path
    local L3="$tmp/l3"
    mkdir -p "$L3"
    : > "$osa"
    LOGD="$L3" STUB_DF_AVAIL_KB=10000000 run --sample;              expect "auto: low space, no report yet, sample ok" 0 'sample:ok'
    if [ ! -e "$L3/disk_headroom_report.txt" ] && grep -q 'Low disk' "$osa" && ! grep -q 'Report: ' "$osa" && grep -q 'not yet available' "$osa"; then pass=$((pass + 1)); echo "PASS: low-space message without report says not yet available"; else fail=$((fail + 1)); echo "FAIL: low-space message without report: $(cat "$osa")"; fi

    rm -rf "$tmp"
    echo "RESULTS: $pass passed, $fail failed"
    [ "$fail" -eq 0 ] && return 0
    return 1
}

main() {
    case "${1:-}" in
        --sample)   shift; [ $# -eq 0 ] || { usage; return 2; }; do_sample ;;
        --check)    shift; do_check "$@" ;;
        --report)   shift; [ $# -eq 0 ] || { usage; return 2; }; do_report ;;
        --selftest) shift; [ $# -eq 0 ] || { usage; return 2; }; do_selftest ;;
        *)          usage; return 2 ;;
    esac
}

main "$@"
exit $?
