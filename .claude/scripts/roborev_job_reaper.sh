#!/usr/bin/env bash
# roborev_job_reaper.sh — reap orphaned/timed-out roborev review_jobs rows,
# and report (never kill) duplicate `roborev daemon run` processes.
#
# Context (JohnGavin/llm#984, #956): roborev's SQLite DB (~/.roborev/reviews.db)
# has no supervision. Jobs whose worker died can sit in status='running'
# forever (observed: 10h12m and 6h04m with zero matching agent process in
# `ps`). The configured `job_timeout_minutes` (global config.toml, overridable
# per-repo via <repo>/.roborev.toml) is not reliably enforced in-process — a
# job was observed to *complete* at 47.5 minutes under a 30-minute limit.
# roborev is a third-party binary we cannot patch; this script is external
# supervision layered on top of it.
#
# review_jobs has NO worker PID column (only a "worker-N" *slot label*,
# populated only once a job actually starts executing — see worker_id in the
# schema). So "worker process no longer exists" cannot be checked per-row
# against an OS PID. Two independently-verifiable signals are used instead:
#
#   1. age-based:   now - started_at (or enqueued_at if started_at is NULL)
#                    exceeds effective_timeout_minutes * REAP_MULTIPLIER,
#                    floored at REAP_FLOOR_MINUTES. The multiplier exists
#                    because the in-process deadline is known-unreliable in
#                    one direction (a job finished at 47.5 min under a 30 min
#                    limit) — using the raw configured value as our own kill
#                    threshold would risk reaping a job that is merely slow,
#                    not dead. effective_timeout=0 means "disabled for this
#                    repo" (roborev's own convention, confirmed against
#                    llm/.roborev.toml) and is NEVER treated as "reap
#                    immediately" — the age check is skipped entirely.
#
#   2. daemon-down:  if NO `roborev daemon run` process exists anywhere on
#                    this machine (checked once, system-wide, at the top of
#                    the run), then nothing could possibly be executing any
#                    'running' row — reap unconditionally, REGARDLESS of the
#                    repo's timeout setting (including effective_timeout=0).
#                    This is the substitute for a per-row PID check: it is a
#                    coarser but unambiguous fact.
#
# Fail-safe bias: a row is reaped only when one of the two signals fires.
# Anything else is kept and logged with its reason. Unparseable timestamps
# are kept (never reaped) and logged as a WARN.
#
# `roborev config get <key>` resolves against the CALLER's cwd (verified
# 2026-08-22: run from inside an llm worktree it returned "0", llm's own
# override, even though most repos should see the global default of 30). This
# script never shells out to `roborev config`; it reads config.toml and each
# repo's own root_path (from the `repos` table, not $PWD) and its
# <root_path>/.roborev.toml directly, so it cannot inherit the wrong repo's
# config the way `roborev config get` can.
#
# Usage:
#   bash roborev_job_reaper.sh              # dry-run (default; never writes)
#   bash roborev_job_reaper.sh --apply      # reap for real (after SOAK_END)
#   SELFTEST=1 bash roborev_job_reaper.sh   # unit + fixture-DB tests
#
# Env overrides (all optional):
#   ROBOREV_DB               default: $HOME/.roborev/reviews.db (READ for
#                             dry-run; READ+WRITE only under --apply)
#   ROBOREV_CONFIG            default: $HOME/.roborev/config.toml
#   ROBOREV_REAPER_LOG_FILE   default: $HOME/.claude/logs/roborev_job_reaper.log
#   UNIFIED_DB_PATH           default: $HOME/.claude/logs/unified.duckdb
#                             (housekeeping_runs heartbeat row only; silently
#                             skipped when duckdb or the DB file is absent)
#   REAP_MULTIPLIER           default: 2   (threshold = effective_timeout * this)
#   REAP_FLOOR_MINUTES        default: 60  (threshold is never below this)
#   ROBOREV_REAPER_FORCE_DAEMON_ALIVE   testing-only: "0"/"1" overrides the
#                             real `ps` scan. NOT for production use.
#
# The reap is a single UPDATE guarded by `AND status='running'`, so a row
# that changed state between the SELECT and the UPDATE (e.g. it actually
# finished) is left alone (rowcount 0, logged as a race, not double-counted).
# This also makes the script idempotent: reaped rows are no longer 'running'
# on the next invocation.
#
# Tracks: JohnGavin/llm#984, JohnGavin/llm#956

set -uo pipefail

export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
PYTHON="${PYTHON:-/usr/bin/python3}"

ROBOREV_DB="${ROBOREV_DB:-$HOME/.roborev/reviews.db}"
ROBOREV_CONFIG="${ROBOREV_CONFIG:-$HOME/.roborev/config.toml}"
LOG_FILE="${ROBOREV_REAPER_LOG_FILE:-$HOME/.claude/logs/roborev_job_reaper.log}"
UNIFIED_DB="${UNIFIED_DB_PATH:-$HOME/.claude/logs/unified.duckdb}"

REAP_MULTIPLIER="${REAP_MULTIPLIER:-2}"
REAP_FLOOR_MINUTES="${REAP_FLOOR_MINUTES:-60}"

# Soak: dry-run only until this date, mirroring worktree_gc.sh's SOAK_END
# pattern — this script mutates a THIRD-PARTY database we do not own, so the
# bar for a soak period is at least as high as for our own worktree GC.
SOAK_END="${ROBOREV_REAPER_SOAK_END:-2026-08-29}"

# ── Logging ───────────────────────────────────────────────────────────────
log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
  echo "$msg"
}

# ── TOML helpers (top-level keys only, i.e. before the first [section]) ────
_toml_top_int() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 0
  awk -v key="$key" '
    BEGIN { in_top = 1 }
    /^\[/ { in_top = 0; next }
    in_top {
      line = $0
      sub(/#.*/, "", line)
      if (line ~ "^[[:space:]]*" key "[[:space:]]*=") {
        sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "", line)
        gsub(/[[:space:]]+$/, "", line)
        if (line != "") { print line; exit }
      }
    }
  ' "$file"
}

_toml_top_str() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 0
  awk -v key="$key" '
    BEGIN { in_top = 1 }
    /^\[/ { in_top = 0; next }
    in_top {
      line = $0
      sub(/#.*/, "", line)
      if (line ~ "^[[:space:]]*" key "[[:space:]]*=") {
        sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "", line)
        gsub(/[[:space:]]+$/, "", line)
        gsub(/^\x27|\x27$/, "", line)
        gsub(/^"|"$/, "", line)
        if (line != "") { print line; exit }
      }
    }
  ' "$file"
}

# ── Effective-timeout resolution (repo override wins; else inherit global) ─
# $1 = global config.toml path, $2 = repo's own .roborev.toml path (may not
# exist). Prints the resolved integer, or "" if neither source has the key —
# callers MUST treat "" as "unknown", never as 0 or as "use some default".
_effective_timeout_minutes() {
  local global_cfg="$1" repo_toml="$2"
  local repo_val=""
  if [ -n "$repo_toml" ] && [ -f "$repo_toml" ]; then
    repo_val=$(_toml_top_int "$repo_toml" "job_timeout_minutes")
  fi
  if [ -n "$repo_val" ]; then
    echo "$repo_val"
    return 0
  fi
  if [ -f "$global_cfg" ]; then
    _toml_top_int "$global_cfg" "job_timeout_minutes"
  fi
}

# ── Timestamp helpers ────────────────────────────────────────────────────
_now_epoch() {
  "$PYTHON" -c "import time; print(int(time.time()))"
}

# Handles both formats seen in review_jobs: naive "YYYY-MM-DD HH:MM:SS"
# (sqlite datetime('now'), UTC) and "YYYY-MM-DDTHH:MM:SS+HH:MM" (roborev's
# own local-time-with-offset writes to started_at/finished_at).
_parse_ts_epoch() {
  local ts="$1"
  [ -z "$ts" ] && return 0
  "$PYTHON" -c "
import sys, datetime
s = sys.argv[1]
try:
    dt = datetime.datetime.fromisoformat(s)
except ValueError:
    sys.exit(0)
if dt.tzinfo is None:
    dt = dt.replace(tzinfo=datetime.timezone.utc)
print(int(dt.timestamp()))
" "$ts" 2>/dev/null
}

# $1 = timestamp string, $2 = now epoch -> age in minutes (1 decimal), or ""
# if the timestamp did not parse.
_job_age_minutes() {
  local ts="$1" now="$2"
  local epoch
  epoch=$(_parse_ts_epoch "$ts")
  [ -z "$epoch" ] && return 0
  "$PYTHON" -c "print(round((${now} - ${epoch}) / 60, 1))" 2>/dev/null
}

# ── Decision (pure function — unit-tested directly) ─────────────────────────
# args: effective_timeout(""|N) age_minutes(""|N.N) daemon_alive(0|1)
#       multiplier floor_minutes
# prints "reap:<reason>" or "keep:<reason>"
_decide_action() {
  local et="$1" age="$2" daemon_alive="$3" mult="$4" floor="$5"

  if [ -z "$age" ]; then
    echo "keep:unparseable_timestamp"
    return 0
  fi

  if [ -n "$et" ] && [ "$et" != "0" ]; then
    local threshold=$(( et * mult ))
    if [ "$threshold" -lt "$floor" ]; then threshold=$floor; fi
    local exceeded
    exceeded=$(awk -v a="$age" -v t="$threshold" 'BEGIN{print (a>=t)?1:0}')
    if [ "$exceeded" = "1" ]; then
      echo "reap:timeout_exceeded age=${age}m threshold=${threshold}m(effective_timeout=${et}m x${mult}) daemon_alive=${daemon_alive}"
      return 0
    fi
  fi

  if [ "$daemon_alive" = "0" ]; then
    echo "reap:no_daemon_process age=${age}m effective_timeout=${et:-unknown}m — status=running but no 'roborev daemon run' process found system-wide"
    return 0
  fi

  if [ -z "$et" ]; then
    echo "keep:timeout_unknown age=${age}m daemon_alive=1 (config unreadable — fail-safe: not reaping on age alone)"
    return 0
  fi

  if [ "$et" = "0" ]; then
    echo "keep:timeout_disabled age=${age}m daemon_alive=1 (effective_timeout=0 for this repo)"
    return 0
  fi

  echo "keep:within_threshold age=${age}m effective_timeout=${et}m"
}

# ── Duplicate-daemon check (report-only — NEVER kills anything) ────────────
# Reads `ps aux`-style text from stdin. Prints "<count>|<pid1>,<pid2>,...".
_count_daemon_processes() {
  local matches count=0 pids=""
  matches=$(grep -F "roborev daemon run" | grep -v grep || true)
  if [ -n "$matches" ]; then
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      count=$((count + 1))
      local pid
      pid=$(echo "$line" | awk '{print $2}')
      if [ -z "$pids" ]; then pids="$pid"; else pids="${pids},${pid}"; fi
    done <<< "$matches"
  fi
  echo "${count}|${pids}"
}

# Best-effort only (relies on lsof); not exercised by SELFTEST.
_port_holder_pid() {
  local addr="$1"
  local port="${addr##*:}"
  [ -z "$port" ] && return 0
  lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $2; exit}'
}

# ── DB access (read-only for the scan; write only inside _mark_failed) ─────
_query_running_jobs() {
  local db="$1"
  "$PYTHON" -c "
import sqlite3, sys
db_path = sys.argv[1]
con = sqlite3.connect(f'file:{db_path}?mode=ro', uri=True)
rows = con.execute('''
  SELECT rj.id, rj.repo_id, r.root_path, rj.started_at, rj.enqueued_at
  FROM review_jobs rj
  JOIN repos r ON r.id = rj.repo_id
  WHERE rj.status = 'running'
  ORDER BY rj.id
''').fetchall()
for row in rows:
    print('\x1f'.join('' if x is None else str(x) for x in row))
con.close()
" "$db" 2>/dev/null
}

# Marks one job failed IF it is still 'running' at write time (race guard).
# Prints the number of rows changed (0 or 1).
_mark_failed() {
  local db="$1" jid="$2" reason="$3"
  local finished_at
  finished_at=$("$PYTHON" -c "import datetime; print(datetime.datetime.utcnow().isoformat()+'Z')")
  "$PYTHON" -c "
import sqlite3, sys
db_path, jid, reason, finished_at = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
con = sqlite3.connect(db_path)
cur = con.execute(
    \"UPDATE review_jobs SET status='failed', error=?, finished_at=? WHERE id=? AND status='running'\",
    (reason, finished_at, jid),
)
con.commit()
print(cur.rowcount)
con.close()
" "$db" "$jid" "$reason" "$finished_at" 2>/dev/null
}

# ── Core reap logic — no soak awareness, no CLI parsing (testable in isolation)
# args: db config apply(0|1) daemon_alive(0|1)
# Sets globals: REAPED KEPT INSPECTED (bash has no return-by-value for 3 ints)
_run_reaper() {
  local db="$1" config="$2" apply="$3" daemon_alive="$4"
  REAPED=0
  KEPT=0
  INSPECTED=0
  local now
  now=$(_now_epoch)

  while IFS=$'\x1f' read -r jid repo_id root_path started_at enqueued_at; do
    [ -z "$jid" ] && continue
    INSPECTED=$((INSPECTED + 1))

    local repo_toml="${root_path}/.roborev.toml"
    local et
    et=$(_effective_timeout_minutes "$config" "$repo_toml")

    local ts="$started_at"
    [ -z "$ts" ] && ts="$enqueued_at"
    local age
    age=$(_job_age_minutes "$ts" "$now")

    local decision action reason
    decision=$(_decide_action "$et" "$age" "$daemon_alive" "$REAP_MULTIPLIER" "$REAP_FLOOR_MINUTES")
    action="${decision%%:*}"
    reason="${decision#*:}"

    if [ "$action" = "reap" ]; then
      if [ "$apply" = "1" ]; then
        local rc
        rc=$(_mark_failed "$db" "$jid" "$reason")
        if [ "$rc" = "1" ]; then
          log "[reaped] job=${jid} repo_id=${repo_id} reason=${reason}"
          REAPED=$((REAPED + 1))
        else
          log "[reap-race] job=${jid} repo_id=${repo_id} (status changed before write — left alone)"
        fi
      else
        log "[would-reap] job=${jid} repo_id=${repo_id} reason=${reason}"
        REAPED=$((REAPED + 1))
      fi
    else
      log "[keep] job=${jid} repo_id=${repo_id} reason=${reason}"
      KEPT=$((KEPT + 1))
    fi
  done < <(_query_running_jobs "$db")
}

# ── housekeeping_runs ledger (best-effort; silently skipped w/o duckdb) ────
_duckdb_ok() {
  command -v duckdb >/dev/null 2>&1 && [ -f "$UNIFIED_DB" ]
}

# ── Main ─────────────────────────────────────────────────────────────────
_main() {
  local apply=0
  for arg in "$@"; do
    [ "$arg" = "--apply" ] && apply=1
  done

  local today past_soak
  today=$("$PYTHON" -c "import datetime; print(datetime.date.today().isoformat())")
  past_soak=$("$PYTHON" -c "print('yes' if '${today}' >= '${SOAK_END}' else 'no')")
  if [ "$past_soak" = "no" ] && [ "$apply" = "1" ]; then
    log "[soak] active until ${SOAK_END} — forcing dry-run (--apply ignored)"
    apply=0
  fi

  log "[start] db=${ROBOREV_DB} config=${ROBOREV_CONFIG} apply=${apply} multiplier=${REAP_MULTIPLIER} floor=${REAP_FLOOR_MINUTES}m"

  local run_id run_started script_abs
  run_id=$("$PYTHON" -c "import uuid; print(str(uuid.uuid4()))")
  run_started=$("$PYTHON" -c "import datetime; print(datetime.datetime.utcnow().isoformat()+'Z')")
  script_abs=$(cd "$(dirname "$0")" 2>/dev/null && pwd -P && echo "$(basename "$0")" || echo "$0")

  if _duckdb_ok; then
    duckdb "$UNIFIED_DB" "
      INSERT OR IGNORE INTO housekeeping_runs
        (id, task, source_script, started_at, status, rows_written)
      VALUES ('${run_id}', 'roborev_job_reaper', '${script_abs}', TIMESTAMPTZ '${run_started}', 'ok', 0);
    " 2>/dev/null || true
  fi

  # ── Duplicate-daemon check (always runs, always report-only) ────────────
  local daemon_info daemon_count daemon_pids daemon_alive
  if [ -n "${ROBOREV_REAPER_FORCE_DAEMON_ALIVE:-}" ]; then
    daemon_alive="$ROBOREV_REAPER_FORCE_DAEMON_ALIVE"
    daemon_count="n/a(forced)"
    daemon_pids=""
  else
    daemon_info=$(ps aux 2>/dev/null | _count_daemon_processes)
    daemon_count="${daemon_info%%|*}"
    daemon_pids="${daemon_info#*|}"
    daemon_alive=0
    [ "${daemon_count:-0}" -gt 0 ] 2>/dev/null && daemon_alive=1
  fi

  if [ "$daemon_alive" = "1" ] && [ "${daemon_count}" != "n/a(forced)" ] && [ "${daemon_count:-0}" -gt 1 ] 2>/dev/null; then
    local server_addr holder_pid
    server_addr=$(_toml_top_str "$ROBOREV_CONFIG" "server_addr")
    holder_pid=""
    [ -n "$server_addr" ] && holder_pid=$(_port_holder_pid "$server_addr")
    log "[duplicate-daemon] WARN count=${daemon_count} pids=${daemon_pids} port=${server_addr:-unknown} holder_pid=${holder_pid:-unknown} — report-only, NOT killing anything"
  else
    log "[daemon-check] count=${daemon_count} pids=${daemon_pids:-none} alive=${daemon_alive}"
  fi

  # ── Reap ──────────────────────────────────────────────────────────────
  _run_reaper "$ROBOREV_DB" "$ROBOREV_CONFIG" "$apply" "$daemon_alive"

  log "[done] inspected=${INSPECTED} reaped=${REAPED} kept=${KEPT} apply=${apply} daemon_count=${daemon_count}"

  if _duckdb_ok; then
    local run_ended
    run_ended=$("$PYTHON" -c "import datetime; print(datetime.datetime.utcnow().isoformat()+'Z')")
    duckdb "$UNIFIED_DB" "
      UPDATE housekeeping_runs
      SET ended_at = TIMESTAMPTZ '${run_ended}', rows_written = ${REAPED}
      WHERE id = '${run_id}';
    " 2>/dev/null || true
  fi
}

# ── SELFTEST ────────────────────────────────────────────────────────────
_selftest() {
  local pass=0 fail=0
  _t() {
    local label="$1" expected="$2" got="$3"
    if [ "$got" = "$expected" ]; then
      pass=$((pass + 1))
      echo "PASS: $label"
    else
      fail=$((fail + 1))
      echo "FAIL: $label (expected '$expected' got '$got')"
    fi
  }

  # NOT `local` — the EXIT trap fires after this function has returned (once
  # _main's caller does `exit $?`), by which point a `local` would already be
  # out of scope under `set -u` and the trap itself would fail with an
  # unbound-variable error.
  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' EXIT

  # ── _toml_top_int / _toml_top_str ────────────────────────────────────
  cat > "$tmpdir/global.toml" <<'EOF'
server_addr = '127.0.0.1:7373'
max_workers = 4
job_timeout_minutes = 30
review_reasoning = 'standard'

[sync]
enabled = false
EOF
  _t "toml: top-level int found" "30" "$(_toml_top_int "$tmpdir/global.toml" "job_timeout_minutes")"
  _t "toml: top-level string found" "127.0.0.1:7373" "$(_toml_top_str "$tmpdir/global.toml" "server_addr")"
  _t "toml: missing key -> empty" "" "$(_toml_top_int "$tmpdir/global.toml" "does_not_exist")"
  _t "toml: missing file -> empty" "" "$(_toml_top_int "$tmpdir/missing.toml" "job_timeout_minutes")"

  cat > "$tmpdir/disabled.toml" <<'EOF'
job_timeout_minutes = 0
EOF
  _t "toml: explicit 0 is returned (not treated as missing)" "0" "$(_toml_top_int "$tmpdir/disabled.toml" "job_timeout_minutes")"

  cat > "$tmpdir/section_only.toml" <<'EOF'
review_reasoning = 'standard'

[sync]
job_timeout_minutes = 999
EOF
  _t "toml: key inside a later section is NOT matched as top-level" "" "$(_toml_top_int "$tmpdir/section_only.toml" "job_timeout_minutes")"

  cat > "$tmpdir/commented.toml" <<'EOF'
job_timeout_minutes = 45   # inline comment
EOF
  _t "toml: trailing comment stripped" "45" "$(_toml_top_int "$tmpdir/commented.toml" "job_timeout_minutes")"

  # ── _effective_timeout_minutes ───────────────────────────────────────
  mkdir -p "$tmpdir/repo_no_toml" "$tmpdir/repo_override" "$tmpdir/repo_no_key" "$tmpdir/repo_disabled"
  cat > "$tmpdir/repo_override/.roborev.toml" <<'EOF'
job_timeout_minutes = 10
EOF
  cat > "$tmpdir/repo_no_key/.roborev.toml" <<'EOF'
review_reasoning = 'standard'
EOF
  cat > "$tmpdir/repo_disabled/.roborev.toml" <<'EOF'
job_timeout_minutes = 0
EOF

  _t "effective: no .roborev.toml -> inherits global" "30" \
    "$(_effective_timeout_minutes "$tmpdir/global.toml" "$tmpdir/repo_no_toml/.roborev.toml")"
  _t "effective: .roborev.toml present, key absent -> inherits global" "30" \
    "$(_effective_timeout_minutes "$tmpdir/global.toml" "$tmpdir/repo_no_key/.roborev.toml")"
  _t "effective: .roborev.toml override wins" "10" \
    "$(_effective_timeout_minutes "$tmpdir/global.toml" "$tmpdir/repo_override/.roborev.toml")"
  _t "effective: .roborev.toml explicit 0 disables (not inherited)" "0" \
    "$(_effective_timeout_minutes "$tmpdir/global.toml" "$tmpdir/repo_disabled/.roborev.toml")"
  _t "effective: neither source has the key -> empty (unknown)" "" \
    "$(_effective_timeout_minutes "$tmpdir/missing.toml" "$tmpdir/repo_no_key/.roborev.toml")"

  # ── timestamp parsing ─────────────────────────────────────────────────
  local epoch_a epoch_b
  epoch_a=$(_parse_ts_epoch "2026-08-21T09:00:09+01:00")
  epoch_b=$(_parse_ts_epoch "2026-08-21T09:30:09+01:00")
  _t "ts: 30-minute gap parses to 1800s" "1800" "$(( epoch_b - epoch_a ))"

  local age_naive
  age_naive=$(_job_age_minutes "2026-08-21 08:00:09" "$(_parse_ts_epoch "2026-08-21T09:00:09+00:00")")
  _t "ts: naive (no-tz) timestamp treated as UTC" "60.0" "$age_naive"

  _t "ts: empty timestamp -> empty age" "" "$(_job_age_minutes "" "1000000000")"
  _t "ts: garbage timestamp -> empty age" "" "$(_job_age_minutes "not-a-date" "1000000000")"

  # ── _decide_action ────────────────────────────────────────────────────
  _t "decide: age exceeds effective_timeout*multiplier -> reap timeout_exceeded" \
    "reap" "$(_decide_action 30 90 1 2 60 | cut -d: -f1)"
  _t "decide: age below threshold -> keep within_threshold" \
    "keep" "$(_decide_action 30 10 1 2 60 | cut -d: -f1)"
  _t "decide: effective_timeout=0, daemon alive -> keep timeout_disabled" \
    "keep" "$(_decide_action 0 500 1 2 60 | cut -d: -f1)"
  _t "decide: effective_timeout=0, daemon DEAD -> reap no_daemon_process (overrides disabled timeout)" \
    "reap" "$(_decide_action 0 500 0 2 60 | cut -d: -f1)"
  _t "decide: effective_timeout unknown, daemon alive -> keep (fail-safe)" \
    "keep" "$(_decide_action "" 500 1 2 60 | cut -d: -f1)"
  _t "decide: unparseable age -> keep regardless of everything else" \
    "keep" "$(_decide_action 30 "" 0 2 60 | cut -d: -f1)"
  _t "decide: floor applies when effective_timeout*multiplier < floor" \
    "keep" "$(_decide_action 5 15 1 2 60 | cut -d: -f1)"   # 5*2=10 < floor 60 -> threshold 60, age 15 kept
  _t "decide: floor applies and age exceeds the floored threshold" \
    "reap" "$(_decide_action 5 65 1 2 60 | cut -d: -f1)"

  # ── _count_daemon_processes ───────────────────────────────────────────
  local zero_matches one_match two_matches
  zero_matches=$(printf 'johngavin 1 0.0 0.0 roborev tui\n' | _count_daemon_processes)
  _t "daemon-count: no matches" "0|" "$zero_matches"

  one_match=$(printf 'johngavin 84249 0.0 0.2 /usr/local/bin/roborev daemon run\n' | _count_daemon_processes)
  _t "daemon-count: one match, pid captured" "1|84249" "$one_match"

  two_matches=$(printf 'johngavin 19023 0.0 0.2 /usr/local/bin/roborev daemon run\njohngavin 19066 0.0 0.2 /usr/local/bin/roborev daemon run\n' | _count_daemon_processes)
  _t "daemon-count: two matches, both pids captured" "2|19023,19066" "$two_matches"

  local grep_line_excluded
  grep_line_excluded=$(printf 'johngavin 1 0.0 0.0 grep -F roborev daemon run\n' | _count_daemon_processes)
  _t "daemon-count: a grep-for-the-pattern line is excluded" "0|" "$grep_line_excluded"

  # ── end-to-end fixture-DB test (NEVER the live DB) ────────────────────
  local fdb="$tmpdir/fixture.db"
  sqlite3 "$fdb" <<'SQL'
CREATE TABLE repos (id INTEGER PRIMARY KEY, root_path TEXT UNIQUE NOT NULL, name TEXT NOT NULL);
CREATE TABLE review_jobs (
  id INTEGER PRIMARY KEY, repo_id INTEGER NOT NULL, status TEXT NOT NULL,
  started_at TEXT, enqueued_at TEXT, finished_at TEXT, worker_id TEXT, error TEXT
);
SQL

  mkdir -p "$tmpdir/repoA" "$tmpdir/repoB" "$tmpdir/repoC"
  # repoA: no .roborev.toml -> inherits global (30)
  # repoB: job_timeout_minutes = 0 -> disabled
  cat > "$tmpdir/repoB/.roborev.toml" <<'EOF'
job_timeout_minutes = 0
EOF
  # repoC: job_timeout_minutes = 10 -> threshold floors to 60 (10*2=20 < 60)
  cat > "$tmpdir/repoC/.roborev.toml" <<'EOF'
job_timeout_minutes = 10
EOF

  sqlite3 "$fdb" "
    INSERT INTO repos (id, root_path, name) VALUES
      (1, '${tmpdir}/repoA', 'repoA'),
      (2, '${tmpdir}/repoB', 'repoB'),
      (3, '${tmpdir}/repoC', 'repoC');
  "

  ts_minus() {
    "$PYTHON" -c "
import datetime, sys
mins = int(sys.argv[1])
print((datetime.datetime.utcnow() - datetime.timedelta(minutes=mins)).isoformat())
" "$1"
  }

  # job1 repoA: 90m old, threshold=60 (30*2) -> REAP (timeout)
  # job2 repoA: 10m old -> KEEP
  # job3 repoB: 500m old, disabled timeout -> KEEP when daemon alive, REAP when daemon dead
  # job4 repoC: 25m old, threshold=60 (floor) -> KEEP
  # job5 repoC: 70m old, threshold=60 (floor) -> REAP
  # job6 repoA: status='done' -> never touched (not in 'running' scan)
  # job7 repoA: started_at NULL, enqueued_at 200m old -> REAP via fallback
  sqlite3 "$fdb" "
    INSERT INTO review_jobs (id, repo_id, status, started_at, enqueued_at) VALUES
      (1, 1, 'running', '$(ts_minus 90)',  '$(ts_minus 91)'),
      (2, 1, 'running', '$(ts_minus 10)',  '$(ts_minus 11)'),
      (3, 2, 'running', '$(ts_minus 500)', '$(ts_minus 501)'),
      (4, 3, 'running', '$(ts_minus 25)',  '$(ts_minus 26)'),
      (5, 3, 'running', '$(ts_minus 70)',  '$(ts_minus 71)'),
      (6, 1, 'done',    '$(ts_minus 999)', '$(ts_minus 1000)'),
      (7, 1, 'running', NULL,               '$(ts_minus 200)');
  "

  LOG_FILE="$tmpdir/reaper.log"

  # dry-run pass, daemon alive=1: expect job1, job5, job7 would-reap; job2,3,4 kept
  _run_reaper "$fdb" "$tmpdir/global.toml" 0 1
  _t "fixture dry-run(daemon alive): inspected=6 (job6 excluded, status=done)" "6" "$INSPECTED"
  _t "fixture dry-run(daemon alive): would-reap count = 3 (job1,5,7)" "3" "$REAPED"
  _t "fixture dry-run(daemon alive): kept count = 3 (job2,3,4)" "3" "$KEPT"

  local status6
  status6=$(sqlite3 "$fdb" "SELECT status FROM review_jobs WHERE id=6")
  _t "fixture dry-run: job6 (status=done) untouched" "done" "$status6"
  local status3_before
  status3_before=$(sqlite3 "$fdb" "SELECT status FROM review_jobs WHERE id=3")
  _t "fixture dry-run: no row is ever mutated in dry-run mode" "running" "$status3_before"

  # dry-run pass, daemon alive=0: with NO daemon process anywhere, nothing
  # could possibly be executing ANY 'running' row, so all 6 are reaped —
  # including job2/job4, which were merely young, not orphaned by timeout.
  # This is deliberate: daemon-down is an unconditional override (see the
  # design note at the top of this file), not just an extra path to the
  # same timeout-based verdict.
  _run_reaper "$fdb" "$tmpdir/global.toml" 0 0
  _t "fixture dry-run(daemon DEAD): would-reap count = 6 (all running rows, daemon-down overrides everything)" "6" "$REAPED"
  _t "fixture dry-run(daemon DEAD): kept count = 0" "0" "$KEPT"

  # apply pass, daemon alive=1: job1, job5, job7 actually marked failed; job3 stays running
  _run_reaper "$fdb" "$tmpdir/global.toml" 1 1
  _t "fixture apply(daemon alive): reaped=3" "3" "$REAPED"
  local st1 st3 st5 st7
  st1=$(sqlite3 "$fdb" "SELECT status FROM review_jobs WHERE id=1")
  st3=$(sqlite3 "$fdb" "SELECT status FROM review_jobs WHERE id=3")
  st5=$(sqlite3 "$fdb" "SELECT status FROM review_jobs WHERE id=5")
  st7=$(sqlite3 "$fdb" "SELECT status FROM review_jobs WHERE id=7")
  _t "fixture apply: job1 -> failed" "failed" "$st1"
  _t "fixture apply: job3 (disabled timeout, daemon alive) stays running" "running" "$st3"
  _t "fixture apply: job5 -> failed" "failed" "$st5"
  _t "fixture apply: job7 -> failed (enqueued_at fallback)" "failed" "$st7"

  local err1
  err1=$(sqlite3 "$fdb" "SELECT error FROM review_jobs WHERE id=1")
  case "$err1" in
    timeout_exceeded*) pass=$((pass+1)); echo "PASS: fixture apply: job1 error reason recorded" ;;
    *) fail=$((fail+1)); echo "FAIL: fixture apply: job1 error reason recorded (got '$err1')" ;;
  esac

  # idempotency: re-running apply against the same (now-failed) rows changes nothing further
  _run_reaper "$fdb" "$tmpdir/global.toml" 1 1
  _t "fixture apply: second run is idempotent (reaped=0, job2/3/4 unaffected)" "0" "$REAPED"

  # daemon-dead pass, apply: job3 now also reaped
  _run_reaper "$fdb" "$tmpdir/global.toml" 1 0
  local st3b
  st3b=$(sqlite3 "$fdb" "SELECT status FROM review_jobs WHERE id=3")
  _t "fixture apply(daemon DEAD): job3 (disabled timeout) now reaped" "failed" "$st3b"
  local err3
  err3=$(sqlite3 "$fdb" "SELECT error FROM review_jobs WHERE id=3")
  case "$err3" in
    no_daemon_process*) pass=$((pass+1)); echo "PASS: fixture apply: job3 error reason is no_daemon_process" ;;
    *) fail=$((fail+1)); echo "FAIL: fixture apply: job3 error reason (got '$err3')" ;;
  esac

  echo ""
  echo "$pass PASS, $fail FAIL"
  [ "$fail" = "0" ] && return 0 || return 1
}

if [ "${SELFTEST:-0}" = "1" ]; then
  _selftest
  exit $?
fi

_main "$@"
