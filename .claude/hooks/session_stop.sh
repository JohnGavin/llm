#!/usr/bin/env bash
# session_stop.sh - Unified session-end checks
# Merges: session_tidy.sh + decision_log_reminder.sh
# Hook: Stop (fires after every Claude response)

set -euo pipefail

CLAUDE_RUNTIME_ROOT="${CLAUDE_RUNTIME_ROOT:-$HOME/.claude}"
CLAUDE_CONTROL_PLANE_ROOT="${CLAUDE_CONTROL_PLANE_ROOT:-$CLAUDE_RUNTIME_ROOT}"
CLAUDE_DIR="$CLAUDE_CONTROL_PLANE_ROOT"
CURRENT_WORK="${CLAUDE_PROJECT_DIR:-.}/.claude/CURRENT_WORK.md"
TODAY=$(date +%Y-%m-%d)

# ── Memory health ─────────────────────────────────────────────────────
MEMORY_DIR=""
for d in "$CLAUDE_DIR"/projects/*/memory; do
  [ -d "$d" ] && MEMORY_DIR="$d" && break
done

if [ -n "$MEMORY_DIR" ] && [ -f "$MEMORY_DIR/MEMORY.md" ]; then
  mem_lines=$(timeout 5 wc -l < "$MEMORY_DIR/MEMORY.md" 2>/dev/null || echo 0)
  if [ "$mem_lines" -gt 180 ]; then
    echo "MEMORY.md: $mem_lines lines - WARN: approaching 200-line truncation limit!"
  fi

  # Stale memory files (>30 days)
  stale_count=0
  stale_files=""
  for f in "$MEMORY_DIR"/*.md; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = "MEMORY.md" ] && continue
    if [ "$(find "$f" -mtime +30 2>/dev/null)" ]; then
      stale_count=$((stale_count + 1))
      stale_files="$stale_files $(basename "$f")"
    fi
  done
  [ "$stale_count" -gt 0 ] && echo "Memory: $stale_count stale files (>30 days):$stale_files"
fi

# ── Uncommitted config ────────────────────────────────────────────────
if [ -d "$CLAUDE_DIR/.git" ] || git -C "$CLAUDE_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  changes=$(git -C "$CLAUDE_DIR" status -s 2>/dev/null | head -5)
  if [ -n "$changes" ]; then
    n_changes=$(echo "$changes" | wc -l | tr -d ' ')
    echo "Config: $n_changes uncommitted changes in $CLAUDE_DIR/"
  fi
fi

# ── Skill audit (only if skills changed) ─────────────────────────────
AUDIT_WRAPPER="$CLAUDE_DIR/scripts/audit_skills_if_changed.sh"
if [ -x "$AUDIT_WRAPPER" ]; then
  timeout 15 "$AUDIT_WRAPPER" 2>/dev/null || true
fi

# ── Model mix log ────────────────────────────────────────────────────
MIX_SCRIPT="$CLAUDE_DIR/scripts/model_mix_log.sh"
if [ -x "$MIX_SCRIPT" ]; then
  timeout 35 "$MIX_SCRIPT" >/dev/null 2>&1 || true
fi

# ── Log session stop to unified DuckDB ───────────────────────────────
_log_script="$CLAUDE_DIR/scripts/log_session.sh"
if [ -x "$_log_script" ] && [ -f "$CLAUDE_RUNTIME_ROOT/logs/.current_session" ]; then
  _sid=$(cat "$CLAUDE_RUNTIME_ROOT/logs/.current_session" 2>/dev/null || echo "")
  "$_log_script" stop "$_sid" "$(basename "$(pwd)")" "" 2>/dev/null || true
fi

# ── Decision log reminder ────────────────────────────────────────────
if [ -f "$CURRENT_WORK" ]; then
  if ! grep -q "### Decisions" "$CURRENT_WORK" 2>/dev/null; then
    if grep -q "$TODAY" "$CURRENT_WORK" 2>/dev/null; then
      echo "Reminder: CURRENT_WORK.md has no ### Decisions section for today."
    fi
  fi
fi

# ── Braindump closed-loop check ─────────────────────────────────────
# Safety net: warn if braindumps were surfaced but not processed this session.
_bd_db="$CLAUDE_RUNTIME_ROOT/logs/unified.duckdb"
if [ -f "$_bd_db" ]; then
  _unprocessed=$(duckdb -list -noheader "$_bd_db" -c "
    SELECT COUNT(*) FROM braindumps WHERE processed_prompt IS NULL;
  " 2>/dev/null | grep -oE '^[0-9]+$' | head -1) || _unprocessed=0

  if [ "${_unprocessed:-0}" -gt 0 ]; then
    echo "BRAINDUMP: $_unprocessed unprocessed braindump(s) — these were surfaced but not acted on."
    echo "  Run: $CLAUDE_DIR/scripts/braindump_act.sh pending"
  fi

  # Check for commits this session that aren't linked to any braindump action
  _session_start_file="$CLAUDE_RUNTIME_ROOT/logs/.session_start_time"
  if [ -f "$_session_start_file" ]; then
    _start_time=$(cat "$_session_start_file" 2>/dev/null || echo "")
    if [ -n "$_start_time" ]; then
      _n_commits=$(git log --oneline --since="$_start_time" 2>/dev/null | wc -l | tr -d ' ') || _n_commits=0
      _n_actions=$(duckdb -list -noheader "$_bd_db" -c "
        SELECT COUNT(*) FROM braindump_actions
        WHERE created_at >= '$_start_time'::TIMESTAMP;
      " 2>/dev/null | grep -oE '^[0-9]+$' | head -1) || _n_actions=0

      if [ "${_n_commits:-0}" -gt 0 ] && [ "${_n_actions:-0}" -eq 0 ] && [ "${_unprocessed:-0}" -gt 0 ]; then
        echo "BRAINDUMP: $_n_commits commits this session but no braindump actions recorded."
        echo "  If these commits address a braindump, link them with braindump_act.sh"
      fi
    fi
  fi
fi

# ── Telemetry data export + deploy (Calibration + Sessions tabs) ────
# Auto-runs export_and_deploy_data.sh (was orphaned — header claimed it ran here).
EXPORT_SCRIPT="$CLAUDE_DIR/scripts/export_and_deploy_data.sh"
if [ -x "$EXPORT_SCRIPT" ]; then
  timeout 180 "$EXPORT_SCRIPT" 2>&1 | tail -3 || true
fi

# --- Prediction calibration: remind about unresolved predictions ---
PRED_DIR="$CLAUDE_RUNTIME_ROOT/predictions"
if [ -d "$PRED_DIR" ]; then
  PROJECT_SLUG=$(echo "${CLAUDE_PROJECT_DIR:-.}" | sed 's|/|-|g; s|^-||')
  PRED_FILE="$PRED_DIR/${PROJECT_SLUG}.jsonl"
  if [ -f "$PRED_FILE" ]; then
    PENDING=$(/usr/bin/python3 -c "
import json
seen = {}
for line in open('$PRED_FILE'):
    line = line.strip()
    if not line: continue
    try:
        d = json.loads(line)
        seen[d['prediction_id']] = d
    except: pass
pending = [v for v in seen.values() if v.get('outcome') is None]
for p in pending:
    print(f\"  {p['prediction_id']}: \\\"{p.get('task_description','')}\\\" (p={p.get('p_success','?')})\")
" 2>/dev/null) || PENDING=""
    if [ -n "$PENDING" ]; then
      N_PENDING=$(echo "$PENDING" | wc -l | tr -d ' ')
      echo "PREDICTION: $N_PENDING unresolved prediction(s) for this project:"
      echo "$PENDING"
      echo "  Record outcomes: record_prediction.sh outcome <id> true/false"
    fi
  fi
fi

# ── Pattern Detection (Phase 1 Validation, Option 4 Hybrid) ──────────────
# IMPORTANT: The Stop hook fires after EVERY Claude response, not only /bye.
# Running pattern detection (paid Opus API call) on every response would be
# a massive cost regression. We gate on a sentinel file that /bye writes
# before invoking the Stop hook. Non-/bye stops skip this block entirely.
# The sentinel (~/.claude/.bye-requested) is deleted immediately after use
# so a crash or abort does not leave a stale sentinel.
_BYE_SENTINEL="${CLAUDE_RUNTIME_ROOT}/.bye-requested"
if [ -f "$_BYE_SENTINEL" ] && [ -f "${CLAUDE_DIR}/scripts/detect_patterns.sh" ]; then
  rm -f "$_BYE_SENTINEL"  # consume sentinel immediately — one-shot
  TRANSCRIPT=$(ls -t "${CLAUDE_RUNTIME_ROOT}/projects/"*/*.jsonl 2>/dev/null | head -1)
  if [ -n "$TRANSCRIPT" ]; then
    PATTERNS=$(timeout 30 "${CLAUDE_DIR}/scripts/detect_patterns.sh" "$TRANSCRIPT" 2>&1) || PATTERNS=""
    if echo "$PATTERNS" | grep -q "Detected workflow patterns"; then
      echo ""
      echo "$PATTERNS"
      echo ""
      # No interactive read — hooks run non-interactively; auto-schedule skillify.
      echo "$TRANSCRIPT" > "${CLAUDE_RUNTIME_ROOT}/.pending_skillify"
      echo "✓ Patterns detected — /skillify will run at next session start."
    fi
  fi
fi

# ── Bounded session-end roborev refine (fire-and-forget) ─────────────────────
# Runs a bounded `roborev refine --since <session-start-sha>` in the background.
# Never blocks /bye. Opt-out: SKIP_SESSION_END_REFINE=1 or .roborev.toml flag.
# Logs: ~/.claude/logs/session_end_refine.log
#
# IMPORTANT: The Stop hook fires after EVERY Claude response, not only /bye.
# We gate this block on the _BYE_SENTINEL (same mechanism used by the
# pattern-detection block above). The sentinel is written by the /bye skill
# before the Stop hook fires, and consumed (rm -f) by the pattern-detection
# block above. Since pattern detection consumes it first, we re-check by
# looking for a second sentinel written specifically for the refine step.
#
# Sentinel path:   ~/.claude/.bye-session-end-refine
# Written by:      /bye skill (session_end.md)
# Consumed below:  rm -f immediately after reading — one-shot per /bye
_REFINE_SENTINEL="${CLAUDE_RUNTIME_ROOT}/.bye-session-end-refine"
_REFINE_SCRIPT="$CLAUDE_DIR/scripts/session_end_refine.sh"
if [ -f "$_REFINE_SENTINEL" ] && [ -x "$_REFINE_SCRIPT" ]; then
  rm -f "$_REFINE_SENTINEL"  # consume sentinel immediately — one-shot
  # Default SKIP=1 for the first 7 days of soak — per #196 rollout plan.
  # After 7 days of clean dry-run-equivalent logs, remove the env-var prefix.
  SKIP_SESSION_END_REFINE=1 nohup "$_REFINE_SCRIPT" >/dev/null 2>&1 &
fi

# ── Entity propagation (projects only) — #137 Phase 3 minimal cut ─────
PROPAGATE="$CLAUDE_DIR/scripts/entity_propagate.sh"
if [ -x "$PROPAGATE" ] && [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
  timeout 10 "$PROPAGATE" 2>/dev/null || true
fi

# ── Semantic drift logger (passive) — #125 Phase 1 ────────────────────
DRIFT="$CLAUDE_DIR/scripts/drift_check.py"
DRIFT_PY="$HOME/.venvs/drift/bin/python3"
[ -x "$DRIFT_PY" ] || DRIFT_PY=python3   # graceful fallback to system python
if [ -x "$DRIFT" ] && [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
  timeout 30 "$DRIFT_PY" "$DRIFT" 2>/dev/null || true
fi

exit 0
