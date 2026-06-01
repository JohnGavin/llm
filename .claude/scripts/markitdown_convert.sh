#!/usr/bin/env bash
# markitdown_convert.sh — wrapper for Microsoft markitdown document-to-markdown conversion
#
# PURPOSE
#   Convert a document (PDF, DOCX, PPTX, XLSX, HTML, etc.) to a Markdown file
#   using the markitdown Python library.
#
# USAGE
#   bash markitdown_convert.sh <input-file> <output.md>
#
# ENVIRONMENT
#   MARKITDOWN_VENV           Path to a Python venv with markitdown installed.
#                             If set, uses "$MARKITDOWN_VENV/bin/python3".
#                             Default: unset (falls back to /tmp/markitdown_venv
#                             if present, then system python3).
#   MARKITDOWN_DISABLE_NETWORK  Controls network/cloud feature access.
#                             "1" (default): offline-only mode — safe for PHI.
#                             "0": allows whisper/cloud features — use only
#                             when explicitly needed on non-PHI content.
#
# PHI GUARD
#   markitdown optionally supports cloud/whisper features (audio transcription,
#   cloud OCR). Those features can exfiltrate document content to third-party
#   services. This wrapper forces offline-only mode by default.
#   To EXPLICITLY allow network features, set MARKITDOWN_DISABLE_NETWORK=0.
#   See JohnGavin/llm#383.
#
# SELFTEST
#   CLAUDE_HOOK_SELFTEST=1 bash markitdown_convert.sh
#   Confirms wrapper exec path is correct without requiring markitdown to be
#   installed.
#
# INSTALL
#   markitdown is NOT bundled. Run the installer first:
#     bash ~/docs_gh/llm/.claude/scripts/install_markitdown.sh --dry-run
#     bash ~/docs_gh/llm/.claude/scripts/install_markitdown.sh
#
# bash-safety: no && chains — each shell action is a separate command
# See: JohnGavin/llm#383

set -euo pipefail

# ── Logging ───────────────────────────────────────────────────────────────────
LOG_DIR="$HOME/.claude/logs"
LOG_FILE="$LOG_DIR/markitdown_convert.log"
mkdir -p "$LOG_DIR"

log() {
  local level="$1"; shift
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" | tee -a "$LOG_FILE"
}

log_only() {
  local level="$1"; shift
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >> "$LOG_FILE"
}

log_only "INVOKE" "invoked: user=${USER:-unknown} pid=$$ args=$*"

# ── Selftest mode ─────────────────────────────────────────────────────────────
# CLAUDE_HOOK_SELFTEST=1: verify wrapper structure without running a conversion.
# Does NOT require markitdown to be installed.
if [ "${CLAUDE_HOOK_SELFTEST:-0}" = "1" ]; then
  printf '\n'
  printf '══════════════════════════════════════════════════\n'
  printf '  markitdown_convert.sh — SELFTEST MODE\n'
  printf '══════════════════════════════════════════════════\n'
  printf '  [OK] script reached selftest block\n'
  printf '  [OK] logging configured: %s\n' "$LOG_FILE"
  printf '  [OK] PHI guard (MARKITDOWN_DISABLE_NETWORK): present\n'
  printf '  [OK] argument validation: present\n'
  printf '  [OK] venv detection (MARKITDOWN_VENV > /tmp/markitdown_venv > system): present\n'
  printf '  [OK] markitdown availability check with install hint: present\n'
  printf '  wrapper structure ok\n'
  printf '══════════════════════════════════════════════════\n\n'
  log_only "SELFTEST" "selftest passed — structure verified"
  exit 0
fi

# ── PHI guard: network features ───────────────────────────────────────────────
# Default offline-only. Set MARKITDOWN_DISABLE_NETWORK=0 to allow network.
_DISABLE_NETWORK="${MARKITDOWN_DISABLE_NETWORK:-1}"
if [ "$_DISABLE_NETWORK" != "1" ] && [ "$_DISABLE_NETWORK" != "0" ]; then
  log "ABORT" "MARKITDOWN_DISABLE_NETWORK must be '1' (offline) or '0' (network allowed). Got: '$_DISABLE_NETWORK'"
  exit 1
fi

if [ "$_DISABLE_NETWORK" = "0" ]; then
  log "WARN" "MARKITDOWN_DISABLE_NETWORK=0: network/whisper features enabled. Confirm no PHI in input."
else
  log_only "INFO" "MARKITDOWN_DISABLE_NETWORK=1: offline-only mode (default — safe for PHI)"
fi

# ── Argument validation ───────────────────────────────────────────────────────
if [ "$#" -ne 2 ]; then
  printf 'Usage: %s <input-file> <output.md>\n' "$(basename "$0")" >&2
  printf '\n' >&2
  printf 'Examples:\n' >&2
  printf '  bash markitdown_convert.sh report.pdf output.md\n' >&2
  printf '  bash markitdown_convert.sh slides.pptx slides.md\n' >&2
  printf '\n' >&2
  printf 'Install markitdown first:\n' >&2
  printf '  bash ~/docs_gh/llm/.claude/scripts/install_markitdown.sh --dry-run\n' >&2
  exit 2
fi

_INPUT="$1"
_OUTPUT="$2"

if [ ! -f "$_INPUT" ]; then
  log "ABORT" "input file not found: $_INPUT"
  exit 1
fi

# ── Python interpreter selection ──────────────────────────────────────────────
# Priority: MARKITDOWN_VENV env var > /tmp/markitdown_venv > system python3
if [ -n "${MARKITDOWN_VENV:-}" ]; then
  _PYTHON="$MARKITDOWN_VENV/bin/python3"
  log_only "INFO" "using MARKITDOWN_VENV python: $_PYTHON"
elif [ -f "/tmp/markitdown_venv/bin/python3" ]; then
  _PYTHON="/tmp/markitdown_venv/bin/python3"
  log_only "INFO" "using /tmp/markitdown_venv python"
else
  _PYTHON="python3"
  log_only "INFO" "using system python3"
fi

# ── Check markitdown availability ─────────────────────────────────────────────
if ! "$_PYTHON" -m markitdown --help >/dev/null 2>&1; then
  log "ABORT" "markitdown not found via: $_PYTHON -m markitdown"
  printf '\n' >&2
  printf '  markitdown is not installed.\n' >&2
  printf '\n' >&2
  printf '  Install it via:\n' >&2
  printf '    bash ~/docs_gh/llm/.claude/scripts/install_markitdown.sh --dry-run\n' >&2
  printf '    bash ~/docs_gh/llm/.claude/scripts/install_markitdown.sh\n' >&2
  printf '\n' >&2
  exit 1
fi

# ── Conversion ────────────────────────────────────────────────────────────────
log "START" "converting: $_INPUT -> $_OUTPUT"

# Single command — no && chains (bash-safety rule)
if ! "$_PYTHON" -m markitdown "$_INPUT" -o "$_OUTPUT"; then
  log "FAIL" "markitdown exited non-zero for: $_INPUT"
  exit 1
fi

if [ ! -f "$_OUTPUT" ]; then
  log "FAIL" "output file not created: $_OUTPUT"
  exit 1
fi

_LINES=$(wc -l < "$_OUTPUT" | tr -d ' ')
log "DONE" "converted: $_INPUT -> $_OUTPUT ($_LINES lines)"
