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
# Agent waterfall (llm#1123, owner decision 2026-10-01):
#   attempt 1 = roborev config default (refine_agent, currently gemini)
#   attempt 2 = --agent claude-code --model sonnet, ONLY when attempt 1 failed
#               for an availability reason (see classify_refine_failure).
#   Unknown failure -> INDETERMINATE, no fallback (conservative on cost);
#   SESSION_END_REFINE_FALLBACK_ON_UNKNOWN=1 flips that.
#   SESSION_END_REFINE_GEMINI_BIN (default gemini) — binary probed for the
#   pre-check; absent -> skip straight to attempt 2.
#   SESSION_END_REFINE_ROBOREV — roborev binary override (tests only).
#
# Bounded by:
#   timeout 120 — hard wall-clock limit (per attempt)
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

ROBOREV="${SESSION_END_REFINE_ROBOREV:-/usr/local/bin/roborev}"
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

# ── Per-repo opt-out (llm#1296) ───────────────────────────────────────────────
# The default refine agent (gemini) is third-party; the claude-code fallback
# is not what protects a private repo either. THIS guard is the control: it
# runs here, before any `roborev refine` call below (both attempts), so a
# marked / no-remote / private-root repo never reaches any agent. Fail closed
# if the guard is missing.
_RRA_LIB=""
for _c in "$(cd "$(dirname "$0")" 2>/dev/null && pwd)/../../git-hooks/lib/roborev_repo_allowed.sh" \
          "$HOME/docs_gh/llm/git-hooks/lib/roborev_repo_allowed.sh"; do
  [ -r "$_c" ] && { _RRA_LIB="$_c"; break; }
done
if [ -z "$_RRA_LIB" ]; then
  log "result=skipped reason=repo-guard-missing"
  exit 0
fi
# shellcheck disable=SC1090
. "$_RRA_LIB"
if ! roborev_repo_allowed "$PROJECT_ROOT" >/dev/null; then
  log "result=skipped reason=roborev-opt-out"
  if [ "${SESSION_END_REFINE_DRYRUN:-}" = "1" ]; then
    echo "skipping (repo opted out of roborev / undecidable)"
  fi
  exit 0
fi

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

# ── Waterfall helpers ─────────────────────────────────────────────────────────
# Availability patterns (extended regex, case-insensitive), taken from real
# ~/.claude/logs/session_end_refine.log strings plus the owner's list: the
# agent could not run at all, so trying another agent is worthwhile.
AVAIL_PATTERNS='quota|rate.?limit|429|resource_exhausted|terminalquotaerror|unauthorized|401|403|api key|GEMINI_API_KEY|no review agent available|no configured agent available|not supported when using|gemini failed|executable file not found|command not found|ENOTFOUND|ECONNREFUSED|connection refused|no such host|network is unreachable|i/o timeout|TLS handshake'
# Non-availability patterns: refused/finished for reasons another agent would
# not change (dirty tree, bad SHA, nothing to do, findings remain).
NONAVAIL_PATTERNS='working tree not clean|is not an ancestor of HEAD|nothing to refine|All reviews passed|max iterations \([0-9]+\) reached'

# classify_refine_failure EXIT_CODE OUTFILE -> availability | nonavailability | unknown
# Availability is checked first: "max iterations reached" is printed even when
# every iteration died on an agent error (401 / unsupported model).
classify_refine_failure() {
  local ec="$1" f="$2"
  if [ "$ec" -eq 124 ]; then echo nonavailability; return; fi
  if grep -qiE "$AVAIL_PATTERNS" "$f" 2>/dev/null; then echo availability; return; fi
  if grep -qiE "$NONAVAIL_PATTERNS" "$f" 2>/dev/null; then echo nonavailability; return; fi
  echo unknown
}

# run_refine_attempt N DESC [extra roborev args...] ; sets EXIT_CODE and TMPLOG
run_refine_attempt() {
  local n="$1" desc="$2"; shift 2
  TMPLOG=$(mktemp /tmp/session_end_refine_XXXXXX.log)
  log "project=$PROJECT_NAME attempt=$n agent=$desc starting"
  timeout 120 \
    "$ROBOREV" refine \
      --since "$START_SHA" \
      --max-iterations 3 \
      --min-severity high \
      --quiet \
      "$@" \
    > "$TMPLOG" 2>&1
  EXIT_CODE=$?
}

GEMINI_BIN="${SESSION_END_REFINE_GEMINI_BIN:-gemini}"

# ── Dry-run mode ──────────────────────────────────────────────────────────────
if [ "${SESSION_END_REFINE_DRYRUN:-}" = "1" ]; then
  echo "attempt 1 (config default agent, gemini): roborev refine --since $START_SHA --max-iterations 3 --min-severity high --quiet"
  echo "attempt 2 (only on availability failure, or if $GEMINI_BIN is absent): roborev refine --since $START_SHA --max-iterations 3 --min-severity high --quiet --agent claude-code --model sonnet"
  echo "  project:   $PROJECT_NAME"
  echo "  root:      $PROJECT_ROOT"
  echo "  state:     $STATE_FILE"
  echo "  log:       $LOGFILE"
  exit 0
fi

# ── Execute bounded refine ────────────────────────────────────────────────────
log "project=$PROJECT_NAME start-sha=$START_SHA starting"

ATTEMPT=1
if ! command -v "$GEMINI_BIN" >/dev/null 2>&1; then
  log "project=$PROJECT_NAME attempt=1 skipped reason=gemini-absent (bin=$GEMINI_BIN) -> claude-code"
  ATTEMPT=2
  run_refine_attempt 2 "claude-code(sonnet)" --agent claude-code --model sonnet
else
  run_refine_attempt 1 "config-default(gemini)"
  if [ "$EXIT_CODE" -ne 0 ]; then
    CLASS=$(classify_refine_failure "$EXIT_CODE" "$TMPLOG")
    FALLBACK=0
    case "$CLASS" in
      availability) FALLBACK=1 ;;
      unknown)
        CLASS="INDETERMINATE"
        if [ "${SESSION_END_REFINE_FALLBACK_ON_UNKNOWN:-0}" = "1" ]; then FALLBACK=1; fi ;;
    esac
    log "project=$PROJECT_NAME attempt=1 exit=$EXIT_CODE class=$CLASS fallback=$FALLBACK"
    if [ "$FALLBACK" -eq 1 ]; then
      cat "$TMPLOG" >> "$LOGFILE" 2>/dev/null || true
      rm -f "$TMPLOG"
      ATTEMPT=2
      run_refine_attempt 2 "claude-code(sonnet)" --agent claude-code --model sonnet
    fi
  fi
fi

if [ "$EXIT_CODE" -eq 124 ]; then
  log "project=$PROJECT_NAME start-sha=$START_SHA attempt=$ATTEMPT result=timeout duration=120s"
  echo "TIMEOUT after 120s" >> "$LOGFILE"
elif [ "$EXIT_CODE" -ne 0 ]; then
  log "project=$PROJECT_NAME start-sha=$START_SHA attempt=$ATTEMPT result=error exit=$EXIT_CODE"
else
  log "project=$PROJECT_NAME start-sha=$START_SHA attempt=$ATTEMPT result=ok"
fi

# Append the final attempt's roborev output to the log
cat "$TMPLOG" >> "$LOGFILE" 2>/dev/null || true
rm -f "$TMPLOG"

exit 0
