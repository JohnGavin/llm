#!/usr/bin/env bash
# launchd_health_audit.sh — Ad-hoc health audit for com.claude.* and com.roborev.* launchd jobs.
#
# Bridges the gap while llm#300's launchd_runs ledger fills up. Run today to
# see which installed plists are loaded, when they last fired, and whether
# they are failing.
#
# Usage:
#   bin/launchd_health_audit.sh [--quiet] [--json] [--out PATH]
#
# Options:
#   --quiet    Show only problem jobs (sections 2, 3, 4); skip "Loaded OK"
#   --json     Emit JSON (one object per job) instead of markdown
#   --out PATH Write output to PATH in addition to stdout
#
# Overrides (env vars for testing):
#   LAUNCHD_AUDIT_PLIST_DIR   Directory to scan instead of ~/Library/LaunchAgents
#   LAUNCHD_AUDIT_MOCK_LIST   Path to a file simulating `launchctl list` output
#   LAUNCHD_AUDIT_NOW_EPOCH   Override "now" epoch for staleness calculations
#
# Log discovery (in priority order for each label L):
#   1. StandardOutPath declared in the plist → use that file's mtime
#   2. ~/. claude/logs/<derived-suffix>.out (suffix: label with com.claude./ com.roborev. stripped,
#      hyphens→underscores)
#   3. ~/.claude/logs/<derived-suffix>.log (same derivation, .log extension)
#
# Requires: macOS (launchctl), /usr/bin/plutil, /usr/bin/python3 (stdlib only)
# Performance: ~2 s for 15 plists
#
# Tracked in: llm#300 (weekly health email)

set -euo pipefail

# ── macOS guard ────────────────────────────────────────────────────────────────
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "launchd_health_audit.sh: macOS only (launchctl not available on $(uname -s))" >&2
  exit 1
fi

# ── Argument parsing ───────────────────────────────────────────────────────────
OPT_QUIET=0
OPT_JSON=0
OPT_OUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quiet) OPT_QUIET=1; shift ;;
    --json)  OPT_JSON=1;  shift ;;
    --out)   OPT_OUT="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ── Paths ──────────────────────────────────────────────────────────────────────
PLIST_DIR="${LAUNCHD_AUDIT_PLIST_DIR:-$HOME/Library/LaunchAgents}"
LOG_DIR="${LOG_DIR:-$HOME/.claude/logs}"
NOW_EPOCH="${LAUNCHD_AUDIT_NOW_EPOCH:-$(/bin/date +%s)}"
PLUTIL=/usr/bin/plutil
PYTHON3=/usr/bin/python3

# ── Helpers ────────────────────────────────────────────────────────────────────

# Parse a plist key from JSON via python3 stdlib (no jq dependency)
plist_json_key() {
  local json="$1" key="$2"
  printf '%s' "$json" | "$PYTHON3" -c "
import sys, json
d = json.load(sys.stdin)
v = d.get('$key', '')
# If it's a list/dict, return a JSON string for further processing
if isinstance(v, (list, dict)):
    print(json.dumps(v))
else:
    print(v)
" 2>/dev/null || true
}

# Derive schedule string from plist JSON
describe_schedule() {
  local json="$1"
  local interval run_at_load sci

  interval="$(printf '%s' "$json" | "$PYTHON3" -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('StartInterval', ''))
" 2>/dev/null || true)"

  run_at_load="$(printf '%s' "$json" | "$PYTHON3" -c "
import sys, json
d = json.load(sys.stdin)
v = d.get('RunAtLoad', False)
print('true' if v else 'false')
" 2>/dev/null || true)"

  sci="$(printf '%s' "$json" | "$PYTHON3" -c "
import sys, json
d = json.load(sys.stdin)
v = d.get('StartCalendarInterval', None)
if v is None:
    pass
elif isinstance(v, list):
    # Multiple intervals: summarise as first..last
    entries = sorted(v, key=lambda x: x.get('Hour',0)*60+x.get('Minute',0))
    def fmt(e): return '%02d:%02d'%(e.get('Hour',0), e.get('Minute',0))
    if len(entries) == 1:
        print('daily %s' % fmt(entries[0]))
    else:
        print('hourly %s-%s (%d times)' % (fmt(entries[0]), fmt(entries[-1]), len(entries)))
elif isinstance(v, dict):
    h = v.get('Hour', 0); m = v.get('Minute', 0)
    wd = v.get('Weekday', None)
    day_str = ''
    if wd is not None:
        days = ['Sun','Mon','Tue','Wed','Thu','Fri','Sat']
        day_str = '%s ' % days[int(wd) % 7]
    print('%sdaily %02d:%02d' % (day_str, h, m))
" 2>/dev/null || true)"

  if [[ -n "$sci" ]]; then
    echo "$sci"
  elif [[ -n "$interval" && "$interval" != "0" ]]; then
    echo "every ${interval}s"
  elif [[ "$run_at_load" == "true" ]]; then
    echo "RunAtLoad=true (daemon)"
  else
    echo "unknown"
  fi
}

# Expected cadence in seconds (to detect staleness)
expected_cadence_seconds() {
  local json="$1"
  printf '%s' "$json" | "$PYTHON3" -c "
import sys, json
d = json.load(sys.stdin)
si = d.get('StartInterval')
if si:
    print(int(si))
    sys.exit()
sci = d.get('StartCalendarInterval')
if sci is None:
    print(86400)  # unknown → assume daily
    sys.exit()
if isinstance(sci, list):
    # Multiple slots: smallest gap between consecutive hours
    entries = sorted(sci, key=lambda x: x.get('Hour',0)*60+x.get('Minute',0))
    if len(entries) > 1:
        diffs = []
        for i in range(1, len(entries)):
            a = entries[i-1].get('Hour',0)*60 + entries[i-1].get('Minute',0)
            b = entries[i].get('Hour',0)*60 + entries[i].get('Minute',0)
            diffs.append((b-a)*60)
        print(min(diffs))
    else:
        print(86400)
    sys.exit()
if isinstance(sci, dict):
    # Daily or weekly
    wd = sci.get('Weekday')
    print(604800 if wd is not None else 86400)
" 2>/dev/null || echo "86400"
}

# Find the most recent log file for a label
find_log_file() {
  local label="$1" plist_out="$2"

  # Priority 1: StandardOutPath from plist
  if [[ -n "$plist_out" && -f "$plist_out" ]]; then
    echo "$plist_out"
    return
  fi

  # Derive suffix: strip prefix, hyphens→underscores
  local suffix
  suffix="$(printf '%s' "$label" | sed 's/^com\.claude\.\|^com\.roborev\.//; s/-/_/g')"

  # Priority 2: <suffix>.out
  if [[ -f "$LOG_DIR/${suffix}.out" ]]; then
    echo "$LOG_DIR/${suffix}.out"
    return
  fi

  # Priority 3: <suffix>.log
  if [[ -f "$LOG_DIR/${suffix}.log" ]]; then
    echo "$LOG_DIR/${suffix}.log"
    return
  fi

  echo ""
}

# Get file mtime as epoch (macOS stat)
file_mtime_epoch() {
  local f="$1"
  [[ -f "$f" ]] || { echo "0"; return; }
  /usr/bin/stat -f '%m' "$f" 2>/dev/null || echo "0"
}

# Get last status line from a log file
last_log_status() {
  local f="$1"
  [[ -f "$f" ]] || { echo ""; return; }
  # Look for error/ok signals in last 20 lines
  local last_error last_ok
  last_error="$(tail -20 "$f" 2>/dev/null | grep -iE 'error|failed|exit [^0]|CRITICAL' | tail -1 || true)"
  last_ok="$(tail -20 "$f" 2>/dev/null | grep -iE 'done|ok|success|exit 0|complete' | tail -1 || true)"

  if [[ -n "$last_error" ]]; then
    printf 'ERROR: %s' "${last_error:0:80}"
  elif [[ -n "$last_ok" ]]; then
    printf 'OK: %s' "${last_ok:0:80}"
  else
    # Just return last non-empty line
    local last_line
    last_line="$(tail -5 "$f" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -1 || true)"
    printf '%s' "${last_line:0:80}"
  fi
}

# Get launchctl list for a label; returns "pid exitcode" or empty
launchctl_info() {
  local label="$1"
  local mock_list="${LAUNCHD_AUDIT_MOCK_LIST:-}"

  if [[ -n "$mock_list" && -f "$mock_list" ]]; then
    grep -F "$label" "$mock_list" 2>/dev/null | head -1 || true
    return
  fi

  launchctl list "$label" 2>/dev/null || true
}

# ── Collect job data ───────────────────────────────────────────────────────────

declare -a JOBS_OK=()
declare -a JOBS_FAILING=()
declare -a JOBS_NOT_LOADED=()
declare -a JOBS_STALE=()

# JSON array accumulator (for --json mode)
JSON_ROWS=""

process_plist() {
  local plist_path="$1"
  local basename
  basename="$(basename "$plist_path")"

  # Skip backups
  [[ "$basename" == *.bak* ]] && return

  # Parse plist to JSON
  local json
  json="$("$PLUTIL" -convert json -o - "$plist_path" 2>/dev/null)" || {
    echo "WARN: could not parse $plist_path" >&2
    return
  }

  # Extract fields
  local label plist_out plist_err
  label="$(plist_json_key "$json" "Label")"
  [[ -z "$label" ]] && return

  plist_out="$(plist_json_key "$json" "StandardOutPath")"
  plist_err="$(plist_json_key "$json" "StandardErrorPath")"

  local schedule cadence
  schedule="$(describe_schedule "$json")"
  cadence="$(expected_cadence_seconds "$json")"

  # launchctl status
  local lc_output lc_loaded lc_pid lc_exit
  lc_output="$(launchctl_info "$label")"
  if [[ -z "$lc_output" ]]; then
    lc_loaded="false"
    lc_pid="-"
    lc_exit="-"
  else
    lc_loaded="true"
    lc_pid="$(printf '%s' "$lc_output" | "$PYTHON3" -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('PID', '-'))
except: print('-')
" 2>/dev/null || echo "-")"
    lc_exit="$(printf '%s' "$lc_output" | "$PYTHON3" -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('LastExitStatus', '-'))
except: print('-')
" 2>/dev/null || echo "-")"
  fi

  # Log file and timing
  local log_file last_fired_epoch last_fired_str hours_stale stale_flag last_status
  log_file="$(find_log_file "$label" "$plist_out")"

  if [[ -n "$log_file" ]]; then
    last_fired_epoch="$(file_mtime_epoch "$log_file")"
  else
    last_fired_epoch="0"
  fi

  if [[ "$last_fired_epoch" -gt 0 ]]; then
    last_fired_str="$(/bin/date -r "$last_fired_epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")"
    local elapsed_s=$(( NOW_EPOCH - last_fired_epoch ))
    hours_stale=$(( elapsed_s / 3600 ))
    # Stale = elapsed > 1.5× expected cadence, minimum 2h for very frequent jobs
    local threshold=$(( cadence * 3 / 2 ))
    [[ "$threshold" -lt 7200 ]] && threshold=7200
    if [[ "$elapsed_s" -gt "$threshold" ]]; then
      stale_flag="STALE(${hours_stale}h)"
    else
      stale_flag=""
    fi
  else
    last_fired_str="never / unknown"
    hours_stale="-"
    stale_flag="STALE(never)"
  fi

  last_status="$(last_log_status "$log_file")"

  # Determine row formatting
  local log_display
  log_display="${log_file:-none}"

  local row
  row="| \`$label\` | $schedule | $lc_loaded (pid=$lc_pid, exit=$lc_exit) | $last_fired_str | $hours_stale | $stale_flag | ${last_status:-—} | $plist_path |"

  # Classify
  if [[ "$lc_loaded" == "false" ]]; then
    JOBS_NOT_LOADED+=("$row")
  elif [[ "$lc_exit" != "-" && "$lc_exit" != "0" && "$lc_exit" != "" ]]; then
    JOBS_FAILING+=("$row")
  elif [[ -n "$stale_flag" ]]; then
    JOBS_STALE+=("$row")
  else
    JOBS_OK+=("$row")
  fi

  # JSON accumulation
  if [[ "$OPT_JSON" -eq 1 ]]; then
    local json_row
    json_row="$(printf '{
  "label": "%s",
  "schedule": "%s",
  "loaded": %s,
  "pid": "%s",
  "last_exit": "%s",
  "last_fired": "%s",
  "hours_stale": "%s",
  "stale": %s,
  "last_status": "%s",
  "log_file": "%s",
  "plist_path": "%s"
}' "$label" "$schedule" "$lc_loaded" "$lc_pid" "$lc_exit" "$last_fired_str" "$hours_stale" \
       "$( [[ -n "$stale_flag" ]] && echo true || echo false )" \
       "$(printf '%s' "$last_status" | sed 's/"/\\"/g')" \
       "$(printf '%s' "$log_display" | sed 's/"/\\"/g')" \
       "$(printf '%s' "$plist_path" | sed 's/"/\\"/g')")"
    if [[ -z "$JSON_ROWS" ]]; then
      JSON_ROWS="$json_row"
    else
      JSON_ROWS="$JSON_ROWS,
$json_row"
    fi
  fi
}

# ── Scan plists ────────────────────────────────────────────────────────────────
shopt -s nullglob
for plist in "$PLIST_DIR"/com.claude.*.plist "$PLIST_DIR"/com.roborev.*.plist; do
  process_plist "$plist"
done
shopt -u nullglob

# ── Render output ──────────────────────────────────────────────────────────────
TABLE_HEADER="| Label | Schedule | Loaded? (pid/exit) | Last fired | Hours stale | Stale? | Last status | Plist |"
TABLE_SEP="|---|---|---|---|---|---|---|---|"

render_markdown() {
  local ts
  ts="$(/bin/date '+%Y-%m-%d %H:%M:%S %Z')"
  local total=$(( ${#JOBS_OK[@]} + ${#JOBS_FAILING[@]} + ${#JOBS_NOT_LOADED[@]} + ${#JOBS_STALE[@]} ))

  cat <<HEADER
# launchd Health Audit

**Generated:** $ts
**Plist directory:** $PLIST_DIR
**Total plists scanned:** $total

---

HEADER

  if [[ "$OPT_QUIET" -eq 0 ]]; then
    echo "## 1. Loaded — OK (${#JOBS_OK[@]})"
    echo ""
    if [[ "${#JOBS_OK[@]}" -gt 0 ]]; then
      echo "$TABLE_HEADER"
      echo "$TABLE_SEP"
      for row in "${JOBS_OK[@]}"; do
        echo "$row"
      done
    else
      echo "_None._"
    fi
    echo ""
  fi

  echo "## 2. Loaded — Recent failures (${#JOBS_FAILING[@]})"
  echo ""
  if [[ "${#JOBS_FAILING[@]}" -gt 0 ]]; then
    echo "$TABLE_HEADER"
    echo "$TABLE_SEP"
    for row in "${JOBS_FAILING[@]}"; do
      echo "$row"
    done
  else
    echo "_None._"
  fi
  echo ""

  echo "## 3. NOT loaded — Installed but inactive (${#JOBS_NOT_LOADED[@]})"
  echo ""
  if [[ "${#JOBS_NOT_LOADED[@]}" -gt 0 ]]; then
    echo "> These jobs have plists installed but are **not loaded** by launchd."
    echo "> Reload with: \`launchctl load -w <plist_path>\`"
    echo ""
    echo "$TABLE_HEADER"
    echo "$TABLE_SEP"
    for row in "${JOBS_NOT_LOADED[@]}"; do
      echo "$row"
    done
  else
    echo "_None._"
  fi
  echo ""

  echo "## 4. Stale — Loaded but overdue (${#JOBS_STALE[@]})"
  echo ""
  if [[ "${#JOBS_STALE[@]}" -gt 0 ]]; then
    echo "$TABLE_HEADER"
    echo "$TABLE_SEP"
    for row in "${JOBS_STALE[@]}"; do
      echo "$row"
    done
  else
    echo "_None._"
  fi
  echo ""

  cat <<FOOTER
---

## 5. Summary

| Status | Count |
|---|---|
| Loaded — OK | ${#JOBS_OK[@]} |
| Loaded — failing | ${#JOBS_FAILING[@]} |
| NOT loaded | ${#JOBS_NOT_LOADED[@]} |
| Stale | ${#JOBS_STALE[@]} |
| **Total** | **$total** |

**Action required:** See sections 2, 3, and 4.
- Section 3 (not loaded): \`launchctl load -w <plist>\`
- Section 2 (failures): check the log file listed in each row
- Section 4 (stale): the job ran but may be stuck; check log and consider unload/reload

See llm#300 for the weekly health email that will automate this.
FOOTER
}

render_json() {
  printf '[\n%s\n]\n' "$JSON_ROWS"
}

# ── Output ─────────────────────────────────────────────────────────────────────
if [[ "$OPT_JSON" -eq 1 ]]; then
  output="$(render_json)"
else
  output="$(render_markdown)"
fi

echo "$output"

if [[ -n "$OPT_OUT" ]]; then
  printf '%s\n' "$output" > "$OPT_OUT"
  echo "(also written to $OPT_OUT)" >&2
fi
