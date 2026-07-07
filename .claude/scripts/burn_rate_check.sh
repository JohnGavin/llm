#!/usr/bin/env bash
# burn_rate_check.sh — Weekly usage burn-rate alert
# Checks if current-week run rate projects to breach the weekly cap.
# Week starts Tuesday, Europe/Dublin timezone.
#
# llm#597: ccusage dropped --start-of-week, which made the old
# `ccusage weekly` invocation fail on every run (guard silently dead).
# The week window is now computed HERE and fetched via
# `ccusage daily --since <week_start>`; spend = totals.totalCost.
# No dependence on ccusage's week bucketing remains.
#
# Usage:
#   burn_rate_check.sh [compact]        # compact = one-line for hooks
#   burn_rate_check.sh [--percent-only] # just the percentage number (for scripts)
#
# Env vars:
#   CLAUDE_WEEKLY_CAP_USD  — weekly budget cap (default: 150)
#   CLAUDE_WEEK_START_DAY  — week start day (default: tuesday)
#   CLAUDE_TIMEZONE        — timezone (default: Europe/Dublin)
#
# Failure visibility (llm#597):
#   stderr of every failed fetch  → ~/.claude/logs/burn_rate_check.err
#   >= 2 consecutive failures     → loud "BURN GUARD DEAD" line instead of
#                                   the quiet burn:err that hid this for days
#
# npx cache-corruption fix (llm#309 Phase 1a):
#   burn_rate_check.err showed weeks of repeated
#   `npm error ENOTEMPTY ... rename ... ccusage-darwin-arm64` failures. Root
#   cause: the 30s `_bounded` timeout SIGTERMs `npx --yes ccusage` mid
#   platform-binary extraction on a cold cache, corrupting the shared
#   ~/.npm/_npx/<hash>/ extraction directory; every subsequent run then
#   raced on the half-extracted dir and failed the same way, forever (npx
#   never re-extracts once a package dir exists, corrupt or not).
#   Fix: install ccusage ONCE to a stable prefix (matching the
#   npm-global-in-nix-shell convention) and exec the installed binary
#   directly on every run — this sidesteps npx's resolution/extraction path
#   entirely, so there is nothing left for the timeout to interrupt. Falls
#   back to the original bounded `npx --yes` call if the local install is
#   ever unavailable.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ETL_FRESHNESS_UPSERT="${SCRIPT_DIR}/etl_freshness_upsert.sh"
UNIFIED_DB="${HOME}/.claude/logs/unified.duckdb"

MODE="${1:-full}"
CAP="${CLAUDE_WEEKLY_CAP_USD:-150}"
WEEK_START="${CLAUDE_WEEK_START_DAY:-tuesday}"
TZ_NAME="${CLAUDE_TIMEZONE:-Europe/Dublin}"

ERR_LOG="$HOME/.claude/logs/burn_rate_check.err"
FAIL_COUNT_FILE="$HOME/.claude/.burn_rate_fail_count"

# ETL freshness registry (llm#309 Phase 1a): 24h cadence. Freshness proxy is
# CACHE_FILE's mtime — it only updates on a *successful* fetch, so a guard
# that silently stops fetching (the exact "BURN GUARD DEAD" failure mode
# above) ages past 24h and flips to status='stale', surfaced at session
# start even before 2 consecutive failures trip the louder canary.
_register_burn_freshness() {
  [ -x "$ETL_FRESHNESS_UPSERT" ] || return 0
  [ -n "${CACHE_FILE:-}" ] || return 0
  "$ETL_FRESHNESS_UPSERT" burn_rate "$UNIFIED_DB" 24 --file "$CACHE_FILE" >/dev/null 2>&1 || true
}

# Consecutive-failure canary (llm#597). A dead guard must get LOUDER, not
# quieter: after 2 consecutive fetch failures the output stops being a quiet
# burn:err and names the log to read.
fail_and_exit() {
  local n=0
  [ -f "$FAIL_COUNT_FILE" ] && n=$(cat "$FAIL_COUNT_FILE" 2>/dev/null || echo 0)
  n=$((n + 1))
  echo "$n" > "$FAIL_COUNT_FILE" 2>/dev/null || true
  _register_burn_freshness
  if [ "$MODE" = "--percent-only" ]; then
    echo "0"  # Always numeric for scripts
  elif [ "$n" -ge 2 ]; then
    echo "BURN GUARD DEAD: usage fetch failed ${n} consecutive runs — burn-rate escalation is NOT protecting you. See $ERR_LOG (llm#597)"
  elif [ "$MODE" = "compact" ]; then
    echo "burn:err"
  else
    echo "Burn rate: could not fetch usage (see $ERR_LOG)"
  fi
  exit 0
}

# Week-start day name → ISO weekday number (date +%u: 1=Mon .. 7=Sun)
case "$(echo "$WEEK_START" | tr '[:upper:]' '[:lower:]')" in
  monday)    week_start_u=1 ;;
  tuesday)   week_start_u=2 ;;
  wednesday) week_start_u=3 ;;
  thursday)  week_start_u=4 ;;
  friday)    week_start_u=5 ;;
  saturday)  week_start_u=6 ;;
  sunday)    week_start_u=7 ;;
  *)         week_start_u=2 ;;  # unknown value — fall back to tuesday
esac

today_u=$(date +%u)
days_since=$(( (today_u - week_start_u + 7) % 7 ))
days_elapsed=$(( days_since + 1 ))  # inclusive of today

# BSD date (-v) first, GNU date (-d) fallback — matches repo convention
week_start_ymd=$(date -v-"${days_since}"d +%Y%m%d 2>/dev/null \
  || date -d "-${days_since} days" +%Y%m%d)

# GNU timeout absent on macOS and under launchd PATH (llm#420)
TIMEOUT_CMD=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)

# _bounded <secs> <cmd> [args...]
# Portable bounded execution. Uses $TIMEOUT_CMD (GNU timeout / gtimeout) when
# available; falls back to perl's alarm(2) built-in, which is always present
# on macOS. If neither is available the command runs unbounded (last resort).
# Root-cause fix: on macOS TIMEOUT_CMD is empty, so the old
# ${TIMEOUT_CMD:+$TIMEOUT_CMD 30} expansion was a no-op — npx ran unbounded.
_bounded() {
  local secs="$1"; shift
  if [ -n "$TIMEOUT_CMD" ]; then
    "$TIMEOUT_CMD" "$secs" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'my $t = shift; alarm $t; exec @ARGV or die "exec: $!"' "$secs" "$@"
  else
    # Last resort: no timeout mechanism available; run unbounded
    "$@"
  fi
}

# ── Local ccusage install (llm#309) ─────────────────────────────────────────
# Installs ccusage ONCE to a stable prefix instead of resolving/extracting it
# through npx on every invocation. Matches the npm-global-in-nix-shell
# convention: --prefix + --cache to an isolated dir (avoids the read-only
# store-prefix issue inside a nix shell, and avoids sharing a cache dir with
# any concurrent install). Returns 0 and leaves $CCUSAGE_BIN executable when
# a usable install is available; returns 1 (never aborts) otherwise so the
# caller can fall back to `npx --yes`.
CCUSAGE_PREFIX="${CCUSAGE_PREFIX:-$HOME/.npm-global}"
CCUSAGE_BIN="${CCUSAGE_PREFIX}/bin/ccusage"

_ensure_ccusage_installed() {
  [ -x "$CCUSAGE_BIN" ] && return 0
  command -v npm >/dev/null 2>&1 || return 1
  mkdir -p "$CCUSAGE_PREFIX" 2>/dev/null || return 1
  _bounded 60 npm install --prefix "$CCUSAGE_PREFIX" \
    --cache "/tmp/ccusage-npm-cache-$$" ccusage@latest \
    >/dev/null 2>>"$ERR_LOG" || true
  [ -x "$CCUSAGE_BIN" ]
}

# Cache: reuse if < 5 minutes old AND for the same week window
CACHE_FILE="/tmp/ccusage_burnweek_${week_start_ymd}_cache.json"
CACHE_MAX_AGE=300

use_cache=false
if [ -f "$CACHE_FILE" ]; then
  # GNU stat (Nix) uses -c %Y, macOS stat uses -f %m
  file_mtime=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || stat -f %m "$CACHE_FILE" 2>/dev/null || echo 0)
  cache_age=$(( $(date +%s) - file_mtime ))
  [ "$cache_age" -lt "$CACHE_MAX_AGE" ] && use_cache=true
fi

if [ "$use_cache" = true ]; then
  daily_json=$(cat "$CACHE_FILE")
else
  err_tmp=$(mktemp /tmp/burn_rate_err_XXXXXX)
  daily_json=""
  if _ensure_ccusage_installed; then
    # Local install (llm#309): bypasses npx's resolution/extraction path —
    # no repeated cache extraction means no ENOTEMPTY race on a timeout kill.
    daily_json=$(_bounded 30 "$CCUSAGE_BIN" daily \
      --since "$week_start_ymd" \
      --timezone "$TZ_NAME" \
      --json --offline </dev/null 2>"$err_tmp") || daily_json=""
  fi
  if [ -z "$daily_json" ]; then
    # Fallback: local install unavailable or its run failed — original path.
    # _bounded: always bounded (perl alarm fallback when GNU timeout absent);
    # --yes: never prompt to install a missing npx package;
    # </dev/null: stdin is /dev/null so any install prompt gets immediate EOF.
    daily_json=$(_bounded 30 npx --yes ccusage daily \
      --since "$week_start_ymd" \
      --timezone "$TZ_NAME" \
      --json --offline </dev/null 2>>"$err_tmp") || {
      {
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) ccusage daily --since $week_start_ymd failed — stderr:"
        cat "$err_tmp"
      } >> "$ERR_LOG" 2>/dev/null || true
      rm -f "$err_tmp"
      _register_burn_freshness
      fail_and_exit
    }
  fi
  rm -f "$err_tmp"
  echo "$daily_json" > "$CACHE_FILE"
fi

# Fetch succeeded — reset the consecutive-failure canary
rm -f "$FAIL_COUNT_FILE" 2>/dev/null || true
_register_burn_freshness

# Parse: spend = totals.totalCost over the since-window (our cap week)
result=$(echo "$daily_json" | python3 -c "
import sys, json

data = json.load(sys.stdin)
rows = data.get('daily', [])
if not rows:
    print('no_data')
    sys.exit(0)

spent = float(data.get('totals', {}).get('totalCost') or 0)

days_elapsed = int(${days_elapsed})
days_remaining = max(0, 7 - days_elapsed)

# Run rate
if days_elapsed > 0:
    daily_rate = spent / days_elapsed
    projected = spent + (daily_rate * days_remaining)
else:
    daily_rate = 0
    projected = spent

cap = float(${CAP})
pct_used = (spent / cap * 100) if cap > 0 else 0
pct_projected = (projected / cap * 100) if cap > 0 else 0

# Determine severity
if pct_projected > 95 or pct_used > 90:
    severity = 'CRITICAL'
elif pct_projected > 80:
    severity = 'WARN'
elif pct_projected > 60:
    severity = 'INFO'
else:
    severity = 'OK'

print(f'{severity}|{spent:.0f}|{projected:.0f}|{cap:.0f}|{days_elapsed}|{days_remaining}|{daily_rate:.0f}|{pct_used:.0f}|{pct_projected:.0f}')
" 2>>"$ERR_LOG") || {
  if [ "$MODE" = "--percent-only" ]; then
    echo "0"  # Always numeric for scripts
  else
    echo "burn:parse_err (see $ERR_LOG)"
  fi
  exit 0
}

if [ "$result" = "no_data" ]; then
  if [ "$MODE" = "--percent-only" ]; then
    echo "0"  # Always numeric for scripts
  elif [ "$MODE" = "compact" ]; then
    echo "burn:no_data"
  else
    echo "Burn rate: no data for current week"
  fi
  exit 0
fi

IFS='|' read -r severity spent projected cap days_elapsed days_remaining daily_rate pct_used pct_projected <<< "$result"

if [ "$MODE" = "--percent-only" ]; then
  # Just the percentage number for scripts
  echo "$pct_used"
elif [ "$MODE" = "compact" ]; then
  # One-line output for hooks/statusline
  case "$severity" in
    CRITICAL) echo "BURN CRITICAL: \$${spent}/\$${cap} (${pct_used}%), proj \$${projected} (${pct_projected}%), ${days_remaining}d left — THROTTLE TO HAIKU" ;;
    WARN)     echo "BURN WARN: \$${spent}/\$${cap} (${pct_used}%), proj \$${projected} (${pct_projected}%), ${days_remaining}d left — prefer sonnet/haiku" ;;
    INFO)     echo "burn:\$${spent}/\$${cap}(${days_remaining}d)" ;;
    OK)       echo "burn:\$${spent}/\$${cap}(${days_remaining}d)" ;;
  esac
else
  # Full output for session start
  echo "Weekly burn rate (${WEEK_START} reset, ${TZ_NAME}):"
  echo "  Spent:     \$${spent} / \$${cap} (${pct_used}%)"
  echo "  Rate:      \$${daily_rate}/day over ${days_elapsed} days"
  echo "  Projected: \$${projected} by week end (${pct_projected}% of cap)"
  echo "  Remaining: ${days_remaining} days"
  case "$severity" in
    CRITICAL)
      echo "  STATUS:    CRITICAL — lockout imminent"
      echo "  ACTION:    Switch to haiku-only. Defer non-urgent work."
      ;;
    WARN)
      echo "  STATUS:    WARNING — on track to breach"
      echo "  ACTION:    Prefer sonnet/haiku. Avoid long opus sessions."
      ;;
    INFO)
      echo "  STATUS:    Elevated — monitor closely"
      ;;
    OK)
      echo "  STATUS:    OK"
      ;;
  esac
fi

exit 0
