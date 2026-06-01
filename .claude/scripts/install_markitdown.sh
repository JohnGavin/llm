#!/usr/bin/env bash
# install_markitdown.sh — markitdown installation guide and pip-venv fallback
#
# PURPOSE
#   Two-path installer for markitdown (Microsoft's document-to-markdown library):
#
#   Path A (PREFERRED): Print the default.R modification needed to add markitdown
#   via Nix/rix, plus the rix regen command. Does NOT modify default.R.
#   This is the right path for a durable, reproducible installation.
#
#   Path B (FALLBACK): Create a pip venv at /tmp/markitdown_venv/ and install
#   markitdown there. Ephemeral (lost on reboot) but immediately usable.
#   Use this when you need markitdown now and can't wait for a Nix regen cycle.
#
# USAGE
#   bash install_markitdown.sh [--dry-run] [--path-b]
#
# FLAGS
#   --dry-run   Print what each path would do without executing anything.
#   --path-b    Execute Path B (pip venv install) instead of just printing Path A.
#               Default (no flag): print Path A instructions only.
#
# SAFETY
#   Refuses to run in agent context (CLAUDE_AGENT=1).
#   --dry-run is always safe.
#
# POST-INSTALL VERIFICATION
#   bash ~/docs_gh/llm/.claude/scripts/markitdown_convert.sh --help
#   /tmp/markitdown_venv/bin/python3 -m markitdown --help  (after Path B)
#
# See JohnGavin/llm#383.

set -euo pipefail

# ── Logging ───────────────────────────────────────────────────────────────────
LOG_DIR="$HOME/.claude/logs"
LOG_FILE="$LOG_DIR/install_markitdown.log"
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

# ── Guard: refuse to run as agent ─────────────────────────────────────────────
if [ "${CLAUDE_AGENT:-0}" = "1" ]; then
  log "ABORT" "CLAUDE_AGENT=1 detected — this script is human-only. Refusing to run."
  printf '\n  This installer modifies your Python environment.\n' >&2
  printf '  It must be run manually in a terminal, not by an agent.\n\n' >&2
  exit 1
fi

# ── Parse flags ───────────────────────────────────────────────────────────────
_DRY_RUN=false
_PATH_B=false

for _arg in "$@"; do
  case "$_arg" in
    --dry-run) _DRY_RUN=true ;;
    --path-b)  _PATH_B=true ;;
    --help|-h)
      printf 'Usage: %s [--dry-run] [--path-b]\n' "$(basename "$0")"
      printf '\n'
      printf '  --dry-run   Print what each path would do (no changes made)\n'
      printf '  --path-b    Install into /tmp/markitdown_venv/ via pip\n'
      printf '\n'
      printf 'Default (no flags): print Path A (Nix/rix) instructions only.\n'
      exit 0
      ;;
    *)
      printf 'Unknown flag: %s\n' "$_arg" >&2
      printf 'Run with --help for usage.\n' >&2
      exit 2
      ;;
  esac
done

# ── Constants ─────────────────────────────────────────────────────────────────
_DEFAULT_R_PATH="$HOME/docs_gh/llm/default.R"
_VENV_PATH="/tmp/markitdown_venv"
_MARKITDOWN_EXTRAS="markitdown[pdf,docx,pptx,xlsx,html]"
_NIX_SHELL_CMD="nix-shell ~/docs_gh/llm/default.nix --run \"Rscript default.R\""

# ── Dry-run banner ────────────────────────────────────────────────────────────
if [ "$_DRY_RUN" = "true" ]; then
  printf '\n'
  printf '═══════════════════════════════════════════════════════════════════\n'
  printf '  install_markitdown.sh — DRY-RUN MODE\n'
  printf '  No changes will be made. Showing what each path would do.\n'
  printf '═══════════════════════════════════════════════════════════════════\n\n'
fi

# ── Path A: Nix/rix installation (PREFERRED) ──────────────────────────────────
printf '── Path A (PREFERRED): Nix/rix install ────────────────────────────\n'
printf '\n'
printf '  This is the reproducible path. markitdown is added to default.R\n'
printf '  so it becomes part of the Nix environment.\n'
printf '\n'
printf '  Step 1: Edit default.R — add markitdown to py_pkgs\n'
printf '\n'
printf '  Current default.R location: %s\n' "$_DEFAULT_R_PATH"
printf '\n'
printf '  Find the py_pkgs line (or add it) and include markitdown:\n'
printf '\n'
printf '    py_pkgs = c(\n'
printf '      "pdfplumber",\n'
printf '      "markitdown"\n'
printf '    )\n'
printf '\n'
printf '  Also ensure py_conf is un-commented in the rix() call:\n'
printf '\n'
printf '    # BEFORE (commented out):\n'
printf '    # py_conf = list(py_version = "3.12", py_pkgs = py_pkgs)\n'
printf '\n'
printf '    # AFTER (un-commented):\n'
printf '    py_conf = list(py_version = "3.12", py_pkgs = py_pkgs)\n'
printf '\n'
printf '  Step 2: Regenerate default.nix using cwd-safe Form A:\n'
printf '\n'
printf '    (cd ~/docs_gh/llm && %s)\n' "$_NIX_SHELL_CMD"
printf '\n'
printf '  Step 3: Exit and re-enter the Nix shell:\n'
printf '\n'
printf '    exit\n'
printf '    cd ~/docs_gh/llm\n'
printf '    bash default.sh\n'
printf '\n'
printf '  Step 4: Verify:\n'
printf '\n'
printf '    python3 -m markitdown --help\n'
printf '\n'
printf '  NOTE: This path modifies default.R and triggers a nix-build cycle.\n'
printf '        Do NOT run the rix() call from an agent (nix-agent-shell-protocol).\n'
printf '\n'

if [ "$_DRY_RUN" = "true" ]; then
  log_only "DRY-RUN" "Path A printed (Nix/rix instructions)"
fi

# ── Path B: pip venv fallback ─────────────────────────────────────────────────
printf '── Path B (FALLBACK): pip venv at %s ───────\n' "$_VENV_PATH"
printf '\n'
printf '  Ephemeral — lost on reboot. Use when you need markitdown now.\n'
printf '  Per llm#62 precedent (pdfplumber nix regression), pip venv is\n'
printf '  the correct fallback when the nix build path is unavailable.\n'
printf '\n'
printf '  Commands that WOULD run:\n'
printf '\n'
printf '    /usr/bin/python3 -m venv %s\n' "$_VENV_PATH"
printf '    %s/bin/pip install "%s"\n' "$_VENV_PATH" "$_MARKITDOWN_EXTRAS"
printf '\n'
printf '  Post-install — set env var so the wrapper finds the venv:\n'
printf '\n'
printf '    export MARKITDOWN_VENV=%s\n' "$_VENV_PATH"
printf '    # Or pass it inline:\n'
printf '    MARKITDOWN_VENV=%s bash ~/docs_gh/llm/.claude/scripts/markitdown_convert.sh input.pdf out.md\n' "$_VENV_PATH"
printf '\n'

if [ "$_DRY_RUN" = "true" ]; then
  log_only "DRY-RUN" "Path B printed (pip venv instructions)"
  printf '═══════════════════════════════════════════════════════════════════\n'
  printf '  DRY-RUN COMPLETE. No files were modified.\n'
  printf '  Re-run without --dry-run to execute Path B, or follow\n'
  printf '  Path A instructions manually.\n'
  printf '═══════════════════════════════════════════════════════════════════\n\n'
  log "COMPLETE" "dry-run finished — both paths printed, no mutations"
  exit 0
fi

# ── Execute Path B when --path-b flag is set ──────────────────────────────────
if [ "$_PATH_B" = "true" ]; then
  printf '\n'
  printf '── Executing Path B ────────────────────────────────────────────────\n'
  log "START" "Path B: creating pip venv at $_VENV_PATH"

  if [ -f "$_VENV_PATH/bin/python3" ]; then
    log "INFO" "venv already exists at $_VENV_PATH — skipping creation"
  else
    log "INFO" "creating venv: /usr/bin/python3 -m venv $_VENV_PATH"
    /usr/bin/python3 -m venv "$_VENV_PATH"
  fi

  log "INFO" "installing: $_MARKITDOWN_EXTRAS"
  "$_VENV_PATH/bin/pip" install --quiet "$_MARKITDOWN_EXTRAS"

  if ! "$_VENV_PATH/bin/python3" -m markitdown --help >/dev/null 2>&1; then
    log "FAIL" "markitdown import failed after install — check pip output above"
    exit 1
  fi

  log "DONE" "Path B complete: markitdown installed at $_VENV_PATH"
  printf '\n'
  printf '  Installation complete.\n'
  printf '\n'
  printf '  To use:\n'
  printf '    export MARKITDOWN_VENV=%s\n' "$_VENV_PATH"
  printf '    bash ~/docs_gh/llm/.claude/scripts/markitdown_convert.sh input.pdf out.md\n'
  printf '\n'
  printf '  Remember: this venv is lost on reboot. Run Path A to make it permanent.\n\n'
  exit 0
fi

# ── Default: Path A instructions only (no execution) ─────────────────────────
# Already printed above. Just confirm completion.
log_only "DONE" "Path A instructions printed. Re-run with --path-b to execute Path B."
printf '  To install via pip venv right now, run:\n'
printf '    bash %s --path-b\n\n' "$(basename "$0")"
