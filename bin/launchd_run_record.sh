#!/usr/bin/env bash
# launchd_run_record.sh — Wrapper that records launchd job run metrics to DuckDB.
#
# Usage:
#   launchd_run_record.sh <label> -- <cmd> [args...]
#
# Records: label, started_at, finished_at, exit_code, peak_rss_mb into
# ~/.claude/logs/launchd_runs.duckdb (schema created on first run).
#
# Example plist ProgramArguments adoption:
#   <array>
#     <string>/bin/bash</string>
#     <string>/path/to/bin/launchd_run_record.sh</string>
#     <string>com.claude.my-job</string>
#     <string>--</string>
#     <string>/bin/bash</string>
#     <string>/path/to/my_script.sh</string>
#   </array>
#
# Tracked in llm#300.

set -euo pipefail

# ── Arg parsing ────────────────────────────────────────────────────────────────

if [[ $# -lt 3 ]]; then
  echo "Usage: launchd_run_record.sh <label> -- <cmd> [args...]" >&2
  exit 1
fi

LABEL="$1"
shift
if [[ "$1" != "--" ]]; then
  echo "launchd_run_record.sh: expected '--' separator after label" >&2
  exit 1
fi
shift   # consume "--"

CMD=("$@")

# ── Configuration ─────────────────────────────────────────────────────────────

LEDGER="${LAUNCHD_LEDGER:-$HOME/.claude/logs/launchd_runs.duckdb}"
LOG_DIR="$(dirname "$LEDGER")"
TIMELOG="$(mktemp /tmp/launchd_time.XXXXXX)"
DUCKDB_BIN="${DUCKDB_BIN:-duckdb}"

# ── Ensure ledger + schema exist ───────────────────────────────────────────────

mkdir -p "$LOG_DIR"

ensure_schema() {
  # Idempotent: CREATE TABLE IF NOT EXISTS
  "$DUCKDB_BIN" "$LEDGER" <<'SQL' 2>/dev/null || true
CREATE TABLE IF NOT EXISTS runs (
  label        VARCHAR NOT NULL,
  started_at   TIMESTAMPTZ NOT NULL,
  finished_at  TIMESTAMPTZ NOT NULL,
  exit_code    INTEGER NOT NULL,
  peak_rss_mb  DOUBLE,
  host         VARCHAR
);
SQL
}

if command -v "$DUCKDB_BIN" &>/dev/null; then
  ensure_schema
else
  echo "launchd_run_record.sh: duckdb not found in PATH — metrics not recorded" >&2
  # Still run the command (wrapper must never block the real job)
  exec "${CMD[@]}"
fi

# ── Run the command under /usr/bin/time ───────────────────────────────────────

STARTED_AT="$(date -u '+%Y-%m-%d %H:%M:%S')"
EXIT_CODE=0

# /usr/bin/time -l on macOS emits "N maximum resident set size" in bytes
if /usr/bin/time -l "${CMD[@]}" 2>"$TIMELOG"; then
  EXIT_CODE=0
else
  EXIT_CODE=$?
fi

FINISHED_AT="$(date -u '+%Y-%m-%d %H:%M:%S')"

# ── Parse peak RSS from time output ──────────────────────────────────────────

PEAK_RSS_MB="NULL"
if [[ -f "$TIMELOG" ]]; then
  # macOS /usr/bin/time -l output: "        N  maximum resident set size"
  rss_bytes=$(grep -i "maximum resident set size" "$TIMELOG" | awk '{print $1}' | head -1)
  if [[ -n "$rss_bytes" && "$rss_bytes" =~ ^[0-9]+$ ]]; then
    # Convert bytes → MB
    PEAK_RSS_MB=$(awk "BEGIN {printf \"%.2f\", $rss_bytes / 1048576}")
  fi
fi
rm -f "$TIMELOG"

# ── Append row to ledger ───────────────────────────────────────────────────────

HOST="$(hostname -s 2>/dev/null || echo 'unknown')"

"$DUCKDB_BIN" "$LEDGER" <<SQL 2>/dev/null || true
INSERT INTO runs (label, started_at, finished_at, exit_code, peak_rss_mb, host)
VALUES (
  '$(echo "$LABEL" | sed "s/'/''/g")',
  TIMESTAMPTZ '${STARTED_AT}+00:00',
  TIMESTAMPTZ '${FINISHED_AT}+00:00',
  ${EXIT_CODE},
  ${PEAK_RSS_MB},
  '$(echo "$HOST" | sed "s/'/''/g")'
);
SQL

exit "$EXIT_CODE"
