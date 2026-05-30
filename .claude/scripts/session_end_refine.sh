#!/usr/bin/env bash
# session_end_refine.sh — Bounded session-end roborev refine runner
#
# Called by session_stop.sh in the background (fire-and-forget, never blocks /bye).
# Reads the session-start SHA recorded by session_init.sh and runs a
# bounded roborev refine on commits made since that SHA.
#
# Controls:
#   SKIP_SESSION_END_REFINE=1          — skip entirely (env opt-out)
#   SESSION_END_REFINE_DRYRUN=1        — print what would run, no actual roborev call
#   .roborev.toml session_end_refine = false — per-project opt-out
#
# Bounded by:
#   timeout 120 — hard wall-clock limit
#   --max-iterations 3 — roborev iteration cap
#   --min-severity high — only high+ findings
#
# Log: ~/.claude/logs/session_end_refine.log

set -uo pipefail   # -u: unset vars are errors; no -e: we exit 0 on all errors

# Wire codex_with_fallback.sh into roborev's codex calls (#365):
_SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
if [ -x "${_SCRIPT_DIR}/codex_shim/codex" ]; then
  export PATH="${_SCRIPT_DIR}/codex_shim:$PATH"
fi
unset _SCRIPT_DIR

ROBOREV="/usr/local/bin/roborev"
LOGFILE="$HOME/.claude/logs/session_end_refine.log"
mkdir -p "$(dirname "$LOGFILE")"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOGFILE"
}

# Sanitise a string for use as a filename component.
# Replaces slashes and spaces with underscores, strips leading underscores.
sanitize() {
  echo "$1" | tr '/ ' '__' | sed 's/^_*//'
}

# ── Determine project root ────────────────────────────────────────────────────
# Non-destructive setup runs BEFORE any opt-out checks so the soak period
# actually exercises repo-resolution and slug-derivation logic (C2 Medium fix).
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || PROJECT_ROOT=""
if [ -z "$PROJECT_ROOT" ]; then
  log "result=skipped reason=not-a-git-repo"
  if [ "${SESSION_END_REFINE_DRYRUN:-}" = "1" ]; then
    echo "skipping (cwd not a git repo)"
  fi
  exit 0
fi
PROJECT_NAME=$(basename "$PROJECT_ROOT")

# ── Read session-start SHA (non-destructive, needed for logging) ──────────────
SLUG=$(sanitize "$PROJECT_NAME")
STATE_FILE="$HOME/.claude/.session_start_sha_${SLUG}"
START_SHA=""
if [ -f "$STATE_FILE" ]; then
  START_SHA=$(head -1 "$STATE_FILE" 2>/dev/null | tr -d '[:space:]')
fi

# ── Env opt-out (AFTER non-destructive setup) ─────────────────────────────────
# The skip exits here — the setup above is exercised in all runs (including soak)
# so the soak validates that repo-resolution and slug/state-file derivation work.
if [ "${SKIP_SESSION_END_REFINE:-}" = "1" ]; then
  log "project=$PROJECT_NAME slug=$SLUG state_file_exists=$([ -f "$STATE_FILE" ] && echo yes || echo no) start_sha=${START_SHA:-EMPTY} result=skipped reason=SKIP_SESSION_END_REFINE"
  echo "skipping (opt-out env var)"
  exit 0
fi

# ── Per-project TOML opt-out ──────────────────────────────────────────────────
TOML="$PROJECT_ROOT/.roborev.toml"
if [ -f "$TOML" ]; then
  if grep -qE '^\s*session_end_refine\s*=\s*false' "$TOML" 2>/dev/null; then
    log "project=$PROJECT_NAME result=skipped reason=toml-opt-out"
    if [ "${SESSION_END_REFINE_DRYRUN:-}" = "1" ]; then
      echo "skipping (project opted out via .roborev.toml: session_end_refine = false)"
    fi
    exit 0
  fi
fi

# ── Validate session-start SHA ────────────────────────────────────────────────
if [ ! -f "$STATE_FILE" ]; then
  log "project=$PROJECT_NAME result=skipped reason=no-session-start-sha"
  if [ "${SESSION_END_REFINE_DRYRUN:-}" = "1" ]; then
    echo "skipping (no session-start SHA)"
  fi
  exit 0
fi

if [ -z "$START_SHA" ]; then
  log "project=$PROJECT_NAME result=skipped reason=empty-state-file"
  if [ "${SESSION_END_REFINE_DRYRUN:-}" = "1" ]; then
    echo "skipping (session-start SHA file is empty)"
  fi
  exit 0
fi

# ── Verify SHA exists in this repo ───────────────────────────────────────────
if ! git -C "$PROJECT_ROOT" cat-file -e "${START_SHA}^{commit}" 2>/dev/null; then
  log "project=$PROJECT_NAME start-sha=$START_SHA result=skipped reason=sha-not-in-repo"
  if [ "${SESSION_END_REFINE_DRYRUN:-}" = "1" ]; then
    echo "skipping (start SHA $START_SHA not found in repo $PROJECT_NAME)"
  fi
  exit 0
fi

# ── Check if roborev is available ────────────────────────────────────────────
if [ ! -x "$ROBOREV" ]; then
  log "project=$PROJECT_NAME result=skipped reason=roborev-not-installed"
  if [ "${SESSION_END_REFINE_DRYRUN:-}" = "1" ]; then
    echo "skipping (roborev not installed at $ROBOREV)"
  fi
  exit 0
fi

# ── Dry-run mode ──────────────────────────────────────────────────────────────
if [ "${SESSION_END_REFINE_DRYRUN:-}" = "1" ]; then
  echo "would run: roborev refine --since $START_SHA --max-iterations 3 --min-severity high --quiet --agent codex"
  echo "  project:   $PROJECT_NAME"
  echo "  root:      $PROJECT_ROOT"
  echo "  state:     $STATE_FILE"
  echo "  log:       $LOGFILE"
  exit 0
fi

# ── Execute bounded refine ────────────────────────────────────────────────────
log "project=$PROJECT_NAME start-sha=$START_SHA starting"

TMPLOG=$(mktemp /tmp/session_end_refine_XXXXXX.log)
# timeout + roborev: one command, no compound
timeout 120 \
  "$ROBOREV" refine \
    --since "$START_SHA" \
    --max-iterations 3 \
    --min-severity high \
    --quiet \
    --agent codex \
  > "$TMPLOG" 2>&1
EXIT_CODE=$?

if [ "$EXIT_CODE" -eq 124 ]; then
  log "project=$PROJECT_NAME start-sha=$START_SHA result=timeout duration=120s"
  echo "TIMEOUT after 120s" >> "$LOGFILE"
elif [ "$EXIT_CODE" -ne 0 ]; then
  log "project=$PROJECT_NAME start-sha=$START_SHA result=error exit=$EXIT_CODE"
else
  log "project=$PROJECT_NAME start-sha=$START_SHA result=ok"
fi

# Append roborev output to log
cat "$TMPLOG" >> "$LOGFILE" 2>/dev/null || true
rm -f "$TMPLOG"

exit 0
