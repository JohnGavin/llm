#!/usr/bin/env bash
# markitdown_convert.sh — Convert documents to Markdown using markitdown
#
# Usage:
#   markitdown_convert.sh <input-file> <output.md>
#
# Supported input formats (first-cut extras: pdf,docx,pptx,xlsx,html):
#   PDF, Word (.docx), PowerPoint (.pptx), Excel (.xlsx), HTML
#   OCR and audio transcription extras are OUT OF SCOPE for this version.
#   See JohnGavin/llm#383 for the [all] extras follow-up.
#
# Installation strategy:
#   PREFERRED: markitdown in the nix shell via default.R py_pkgs slot.
#     markitdown is listed in py_pkgs but py_conf is currently commented out
#     in the rix() call (heavy Python transitive deps slow the nix build).
#     When py_conf is re-enabled, this script will use the nix-installed binary.
#
#   FALLBACK (current default): pip venv at /tmp/markitdown_venv/
#     Per llm#62 precedent (pdfplumber -> twisted regression), when the nix
#     build path is unavailable we fall back to a /tmp pip venv. This venv is
#     ephemeral (lost on reboot) but correct for ad-hoc conversion.
#
# PHI / Privacy:
#   markitdown runs locally. No data leaves the machine.
#   Do NOT pass mycare PHI files through this wrapper without confirming
#   local-only execution (whisper / image LLM calls are disabled in this config
#   because we use [pdf,docx,pptx,xlsx,html] not [all]).
#
# bash-safety: single-command body — no && chains inside this script
# See: JohnGavin/llm#383

set -euo pipefail

VENV_PATH="/tmp/markitdown_venv"
INPUT_FILE="${1:-}"
OUTPUT_FILE="${2:-}"

if [ -z "$INPUT_FILE" ] || [ -z "$OUTPUT_FILE" ]; then
  echo "Usage: $0 <input-file> <output.md>" >&2
  exit 1
fi

if [ ! -f "$INPUT_FILE" ]; then
  echo "ERROR: Input file not found: $INPUT_FILE" >&2
  exit 1
fi

# Resolve markitdown binary — prefer nix-shell PATH, fall back to venv
MARKITDOWN_BIN=""
if command -v markitdown > /dev/null 2>&1; then
  MARKITDOWN_BIN="markitdown"
else
  # Venv fallback: create if missing
  if [ ! -f "${VENV_PATH}/bin/markitdown" ]; then
    echo "markitdown not in PATH; creating pip venv at ${VENV_PATH} ..." >&2
    /usr/bin/python3 -m venv "${VENV_PATH}"
    "${VENV_PATH}/bin/pip" install --quiet "markitdown[pdf,docx,pptx,xlsx,html]"
    echo "markitdown installed in venv." >&2
  fi
  MARKITDOWN_BIN="${VENV_PATH}/bin/markitdown"
fi

# Run conversion (single command — no &&)
"${MARKITDOWN_BIN}" "${INPUT_FILE}" -o "${OUTPUT_FILE}"

echo "Converted: ${INPUT_FILE} -> ${OUTPUT_FILE}" >&2
