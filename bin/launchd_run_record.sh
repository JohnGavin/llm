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

# ── Secrets (llm#791 / llm#936) ───────────────────────────────────────────────
# Every job that runs through this wrapper inherits the environment loaded here.
# ~/.config/secrets.env is the single source of truth; ~/.zshenv sources it for
# zsh, but launchd does not run a shell, so without this line a launchd job sees
# only its plist's EnvironmentVariables (typically just PATH).
#
# This is the one edit point that covers every job using the recorder. Daemons
# started outside it — e.g. com.roborev.auto-refine — must load it themselves.
#
# Deliberately NOT fail-loud here: this wrapper is generic and most jobs need no
# secrets at all. Jobs with a hard requirement assert their own (see
# roborev_auto_refine.sh). Missing-file is silent by design; the file is
# optional on a machine that has no secrets.
if [ -r "$HOME/.config/secrets.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$HOME/.config/secrets.env"
  set +a
fi

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

# ── Timeout enforcement (llm#1190) ────────────────────────────────────────────
# One place to bound every recorded launchd job, per-label, rather than 39
# separate plist edits. Policy (llm#1190): every job declares a timeout
# unless there is an explicit recorded reason not to
# (.claude/state/launchd-timeout-exempt.txt) — this is the enforcement half;
# .claude/scripts/launchd_health_report.R's Section 7 is the reporting half.
TIMEOUTS_FILE="${LAUNCHD_TIMEOUTS_FILE:-$HOME/docs_gh/llm/.claude/state/launchd-timeouts.txt}"

# lookup_timeout_seconds LABEL FILE
# Prints the configured bound in seconds for LABEL if FILE declares one;
# returns non-zero (prints nothing) otherwise -- unreadable/missing file, no
# entry, or a malformed entry. Format: "<label>  <seconds>  # reason", one
# entry per line. Parsing mirrors read_timeout_exemptions() in
# launchd_health_report.R: strip from the first '#' to end of line, trim,
# skip blank/comment-only lines. Documented fully in the timeouts file's own
# header.
lookup_timeout_seconds() {
  local label="$1" file="$2"
  [ -r "$file" ] || return 1
  awk -v want="$label" '
    {
      line = $0
      sub(/#.*/, "", line)
      gsub(/^[ \t]+/, "", line)
      gsub(/[ \t]+$/, "", line)
      if (line == "") next
      n = split(line, parts, /[ \t]+/)
      if (n >= 2 && parts[1] == want) { print parts[2]; found = 1; exit }
    }
    END { if (!found) exit 1 }
  ' "$file"
}

TIMEOUT_BOUND_S=""
if TIMEOUT_LOOKUP="$(lookup_timeout_seconds "$LABEL" "$TIMEOUTS_FILE" 2>/dev/null)" \
   && [[ "$TIMEOUT_LOOKUP" =~ ^[0-9]+$ ]]; then
  TIMEOUT_BOUND_S="$TIMEOUT_LOOKUP"
fi

# Resolve a GNU-compatible `timeout` binary. macOS ships no built-in
# `timeout` -- it comes from GNU coreutils, often installed as `gtimeout`
# (Homebrew's default, to avoid clobbering any BSD tool of the same name).
# This repo has hit exactly this "present on one machine, absent on another"
# gap before (nix-agent-shell-protocol, llm#644) -- detect, never assume.
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout"
fi

# RUN_CMD is what actually executes. TIMEOUT_STATUS_WORD is one of:
#   none        -- no bound configured for this label (unchanged behaviour)
#   ok          -- bound configured and enforced; corrected to "killed"
#                  below if the bound actually fires
#   unenforced  -- bound configured but NO timeout binary was found; the job
#                  still runs, UNBOUNDED, and this is recorded distinguishably
#                  rather than silently pretending the bound applied
#   killed      -- the bound fired and the job was terminated at it
RUN_CMD=("${CMD[@]}")
TIMEOUT_STATUS_WORD="none"

if [[ -n "$TIMEOUT_BOUND_S" ]]; then
  if [[ -n "$TIMEOUT_BIN" ]]; then
    RUN_CMD=("$TIMEOUT_BIN" "$TIMEOUT_BOUND_S" "${CMD[@]}")
    TIMEOUT_STATUS_WORD="ok"
  else
    echo "launchd_run_record.sh: WARNING -- timeout of ${TIMEOUT_BOUND_S}s configured for label '$LABEL' in $TIMEOUTS_FILE but no timeout binary (timeout/gtimeout) found on PATH -- running UNBOUNDED" >&2
    TIMEOUT_STATUS_WORD="unenforced"
  fi
fi
# launchd jobs run with a minimal PATH (no Homebrew/nix dirs), so `duckdb` on PATH
# resolves interactively but NOT under launchd — the recorder would silently no-op
# ("duckdb not found — metrics not recorded"). Fall back to common absolute install
# locations so metrics still record for scheduled jobs (llm#300).
if ! command -v "$DUCKDB_BIN" &>/dev/null; then
  for _duckdb_cand in /opt/homebrew/bin/duckdb /usr/local/bin/duckdb; do
    if [ -x "$_duckdb_cand" ]; then DUCKDB_BIN="$_duckdb_cand"; break; fi
  done
fi

# ── Ensure ledger + schema exist ───────────────────────────────────────────────

mkdir -p "$LOG_DIR"

ensure_schema() {
  # Idempotent: CREATE TABLE IF NOT EXISTS / ADD COLUMN IF NOT EXISTS
  "$DUCKDB_BIN" "$LEDGER" <<'SQL' 2>/dev/null || true
CREATE TABLE IF NOT EXISTS runs (
  label        VARCHAR NOT NULL,
  started_at   TIMESTAMPTZ NOT NULL,
  finished_at  TIMESTAMPTZ NOT NULL,
  exit_code    INTEGER NOT NULL,
  peak_rss_mb  DOUBLE,
  host         VARCHAR
);
-- llm#1190: timeout_bound_s is the configured bound (NULL = none declared);
-- timeout_status distinguishes the three determinate outcomes of a declared
-- bound ('ok' = enforced, not hit; 'killed' = enforced, hit; 'unenforced' =
-- declared but no timeout binary was available) from "no bound at all"
-- (both columns NULL). Never conflate "not hit" with "not checked".
ALTER TABLE runs ADD COLUMN IF NOT EXISTS timeout_bound_s INTEGER;
ALTER TABLE runs ADD COLUMN IF NOT EXISTS timeout_status VARCHAR;
SQL
}

if command -v "$DUCKDB_BIN" &>/dev/null; then
  ensure_schema
else
  echo "launchd_run_record.sh: duckdb not found in PATH — metrics not recorded" >&2
  # Still run the command (wrapper must never block the real job) -- but a
  # configured timeout bound is a safety control, not a reporting nicety, so
  # it must still apply even when metrics can't be written (llm#1190). RUN_CMD
  # already carries the timeout wrapper when a bound + binary are available.
  exec "${RUN_CMD[@]}"
fi

# ── Run the command under /usr/bin/time ───────────────────────────────────────

STARTED_AT="$(date -u '+%Y-%m-%d %H:%M:%S')"
STARTED_EPOCH="$(date -u '+%s')"
EXIT_CODE=0

# /usr/bin/time -l on macOS emits "N maximum resident set size" in bytes.
# CRITICAL (llm#928): use `-o "$TIMELOG"` — NOT `2>"$TIMELOG"` — so the wrapped
# job's own stderr passes straight through to this script's stderr (and from
# there to the plist's StandardErrorPath). `-o` diverts ONLY /usr/bin/time's
# own resource-usage report into $TIMELOG; the job's diagnostics are never
# captured or deleted. Verified: `man time` (macOS) — "-o file: Write the
# output to file instead of stderr."
#
# RUN_CMD is CMD, optionally prefixed with `timeout <bound>` (llm#1190) --
# see the "Timeout enforcement" section above.
if /usr/bin/time -l -o "$TIMELOG" "${RUN_CMD[@]}"; then
  EXIT_CODE=0
else
  EXIT_CODE=$?
fi

FINISHED_AT="$(date -u '+%Y-%m-%d %H:%M:%S')"
FINISHED_EPOCH="$(date -u '+%s')"

# ── Distinguish "killed at the bound" from "the job itself exited 124" ───────
# GNU timeout reports exit 124 whenever IT terminates the child for exceeding
# the bound -- but it ALSO reports 124 unchanged if the wrapped command
# happens to exit 124 on its own (verified: `timeout 30 bash -c 'exit 124'`
# also returns 124 after ~0s -- the exit code alone cannot tell the two
# apart). Wall-clock elapsed time can: a real timeout-kill takes at least the
# declared bound; a command that organically exits 124 does not. A small
# tolerance (2s) absorbs scheduling/process-teardown jitter without
# misclassifying a job that legitimately finished just under the bound.
if [[ "$TIMEOUT_STATUS_WORD" == "ok" ]]; then
  ELAPSED_S=$(( FINISHED_EPOCH - STARTED_EPOCH ))
  if [[ "$EXIT_CODE" -eq 124 ]] && [[ "$ELAPSED_S" -ge $(( TIMEOUT_BOUND_S - 2 )) ]]; then
    TIMEOUT_STATUS_WORD="killed"
    echo "launchd_run_record.sh: label '$LABEL' KILLED at its ${TIMEOUT_BOUND_S}s timeout bound (elapsed ${ELAPSED_S}s)" >&2
  fi
fi

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

# SQL literals for the timeout columns: NULL when no bound was configured at
# all; the bound + a quoted status word otherwise. Never write a status word
# without also recording what bound produced it (llm#1190).
if [[ "$TIMEOUT_STATUS_WORD" == "none" ]]; then
  TIMEOUT_BOUND_SQL="NULL"
  TIMEOUT_STATUS_SQL="NULL"
else
  TIMEOUT_BOUND_SQL="${TIMEOUT_BOUND_S}"
  TIMEOUT_STATUS_SQL="'${TIMEOUT_STATUS_WORD}'"
fi

"$DUCKDB_BIN" "$LEDGER" <<SQL 2>/dev/null || true
INSERT INTO runs (label, started_at, finished_at, exit_code, peak_rss_mb, host, timeout_bound_s, timeout_status)
VALUES (
  '$(echo "$LABEL" | sed "s/'/''/g")',
  TIMESTAMPTZ '${STARTED_AT}+00:00',
  TIMESTAMPTZ '${FINISHED_AT}+00:00',
  ${EXIT_CODE},
  ${PEAK_RSS_MB},
  '$(echo "$HOST" | sed "s/'/''/g")',
  ${TIMEOUT_BOUND_SQL},
  ${TIMEOUT_STATUS_SQL}
);
SQL

exit "$EXIT_CODE"
