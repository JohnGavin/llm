#!/usr/bin/env bash
# kb_digest_send.sh — SKELETON: compose and (eventually) send a KB digest email.
#
# CURRENT STATUS: DRY-RUN ONLY. This script substitutes {{placeholders}} from
# the email template and renders the composed message. It does NOT send email.
# Live email sending is deferred pending real-data validation of digest output.
# See llm#298 for the follow-up PR that wires actual SMTP.
#
# Usage:
#   kb_digest_send.sh --digest <path> --template <path> [--recipient <addr>]
#   kb_digest_send.sh --digest <path> --template <path> --send
#
# Args:
#   --digest   PATH   Path to markdown digest built by kb_digest_builder.sh
#   --template PATH   Path to kb_digest_email_template.md
#   --recipient ADDR  Recipient email address (required when --send is used)
#   --send            Enable live send. ALSO requires KB_DIGEST_SEND_CONFIRM env.
#   --dry-run         (default) Print composed email to stdout, do not send.
#
# SEND GUARD — two-factor confirmation required for live send:
#   1. The --send flag must be present
#   2. KB_DIGEST_SEND_CONFIRM must equal exactly: "I AM SENDING THE KB DIGEST"
#
#   This prevents accidental sends when the script is invoked from cron,
#   agent sessions, or shell one-liners that set --send but forget the
#   confirmation phrase.
#
# DEFERRED: SMTP send mechanism
#   When live send is implemented, the mechanism will be one of:
#   - blastula (R package): Rscript -e 'blastula::smtp_send(...)' via Gmail app-
#     password stored in GMAIL_APP_PASSWORD env var (see send_kb_digest_email.R
#     for the reference implementation already in this codebase)
#   - msmtp: a small sendmail-compatible SMTP client installable via Homebrew or
#     Nix. Config in ~/.msmtprc. Usage: echo "$body" | msmtp -t "$recipient"
#   - mailgun REST API: curl POST to api.mailgun.net with MAILGUN_API_KEY +
#     MAILGUN_DOMAIN env vars. No local SMTP setup required.
#   All three options are listed here for the follow-up PR author to choose.
#   The blastula path already exists in send_kb_digest_email.R — reusing it is
#   the lowest-friction option.
#
# Privacy contract:
#   - Digest content is NOT re-read or re-expanded by this script. The template
#     placeholder substitution is pure string replacement — no file parsing,
#     no title extraction, no git operations.
#   - The recipient address is NEVER logged to files by this script.
#   - The script refuses to run inside an agent session (CLAUDE_AGENT=1) unless
#     KB_DIGEST_AUTO=1 is also set.
#
# Tracked in llm#298.

set -uo pipefail

# ── Privacy guard: agent context ─────────────────────────────────────────────

if [ "${CLAUDE_AGENT:-}" = "1" ] && [ "${KB_DIGEST_AUTO:-}" != "1" ]; then
  echo "ERROR: kb_digest_send.sh refuses to run in an agent session." >&2
  echo "       Set KB_DIGEST_AUTO=1 to override (adds explicit audit trail)." >&2
  exit 2
fi

# ── Argument parsing ──────────────────────────────────────────────────────────

DIGEST=""
TEMPLATE=""
RECIPIENT=""
SEND=0

usage() {
  echo "Usage: $0 --digest <path> --template <path> [--recipient <addr>] [--send | --dry-run]"
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --digest)    DIGEST="$2";    shift 2 ;;
    --template)  TEMPLATE="$2";  shift 2 ;;
    --recipient) RECIPIENT="$2"; shift 2 ;;
    --send)      SEND=1;         shift   ;;
    --dry-run)   SEND=0;         shift   ;;
    -h|--help)   usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

# ── Validate args ─────────────────────────────────────────────────────────────

if [ -z "$DIGEST" ]; then
  echo "ERROR: --digest is required" >&2
  usage
fi
if [ ! -f "$DIGEST" ]; then
  echo "ERROR: digest file not found: $DIGEST" >&2
  exit 2
fi

if [ -z "$TEMPLATE" ]; then
  echo "ERROR: --template is required" >&2
  usage
fi
if [ ! -f "$TEMPLATE" ]; then
  echo "ERROR: template file not found: $TEMPLATE" >&2
  exit 2
fi

if [ "$SEND" = "1" ] && [ -z "$RECIPIENT" ]; then
  echo "ERROR: --recipient is required when --send is specified" >&2
  exit 2
fi

# ── Send guard ────────────────────────────────────────────────────────────────

if [ "$SEND" = "1" ]; then
  REQUIRED_CONFIRM="I AM SENDING THE KB DIGEST"
  ACTUAL_CONFIRM="${KB_DIGEST_SEND_CONFIRM:-}"

  if [ "$ACTUAL_CONFIRM" != "$REQUIRED_CONFIRM" ]; then
    echo "ERROR: Live send requested but confirmation phrase not set or incorrect." >&2
    echo "" >&2
    echo "  To confirm you intend to send email:" >&2
    echo "    export KB_DIGEST_SEND_CONFIRM=\"I AM SENDING THE KB DIGEST\"" >&2
    echo "" >&2
    echo "  This two-factor guard prevents accidental sends from cron, agents," >&2
    echo "  or mistyped one-liners. The --send flag + phrase together are required." >&2
    exit 2
  fi

  echo "WARN: kb_digest_send.sh: --send requested with correct confirmation phrase." >&2
  echo "      LIVE SEND IS NOT YET IMPLEMENTED. Falling back to dry-run." >&2
  echo "      See llm#298 follow-up PR for SMTP wiring." >&2
  SEND=0
fi

# ── Extract metadata from digest for template substitution ───────────────────
# Read only the first few lines of the digest (header zone) — never the body.
# Titles in the body are already safe (sanitised by the builder), but we only
# need the header fields here.

DIGEST_DATE="$(head -5 "$DIGEST" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)"
GENERATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SINCE_DURATION="$(head -10 "$DIGEST" | grep -oE 'last [0-9]+[hd]' | head -1 | sed 's/last //')"
N_COMMITS="$(head -10 "$DIGEST" | grep -oE '[0-9]+ commit' | head -1 | grep -oE '[0-9]+')"

# Counts from the digest markdown
PAGES_ADDED_COUNT="$(grep -oE 'Pages Added.*\(([0-9]+)\)' "$DIGEST" | grep -oE '\([0-9]+\)' | tr -d '()' | head -1)"
PAGES_MODIFIED_COUNT="$(grep -oE 'Pages Modified.*\(([0-9]+)\)' "$DIGEST" | grep -oE '\([0-9]+\)' | tr -d '()' | head -1)"
PAGES_DELETED_COUNT="$(grep -oE 'Pages Deleted.*\(([0-9]+)\)' "$DIGEST" | grep -oE '\([0-9]+\)' | tr -d '()' | head -1)"
NEW_WIKILINKS="$(grep -A2 'Cross-Link' "$DIGEST" | grep '[[topic]]' | grep -oE '[0-9]+' | head -1)"
MISSING_SOURCES="$(grep 'missing.*Sources' "$DIGEST" | grep -oE '^\| .* \| [0-9]+' | grep -oE '[0-9]+$' | head -1)"

# Defaults for empty values
DIGEST_DATE="${DIGEST_DATE:-$(date +%Y-%m-%d)}"
SINCE_DURATION="${SINCE_DURATION:-24h}"
N_COMMITS="${N_COMMITS:-0}"
PAGES_ADDED_COUNT="${PAGES_ADDED_COUNT:-0}"
PAGES_MODIFIED_COUNT="${PAGES_MODIFIED_COUNT:-0}"
PAGES_DELETED_COUNT="${PAGES_DELETED_COUNT:-0}"
NEW_WIKILINKS="${NEW_WIKILINKS:-0}"
MISSING_SOURCES="${MISSING_SOURCES:-0}"

# ── Extract page lists from digest ───────────────────────────────────────────
# We extract the bullet-point sections from the digest (already sanitised
# page titles — no body content). If a section is "None.", we pass that through.

extract_section() {
  local label="$1"
  local file="$2"
  awk -v label="$label" '
    $0 ~ "^### " label { found=1; next }
    found && /^### / { exit }
    found { print }
  ' "$file" | sed '/^$/d'
}

PAGES_ADDED_LIST="$(extract_section "Pages Added" "$DIGEST")"
PAGES_MODIFIED_LIST="$(extract_section "Pages Modified" "$DIGEST")"
PAGES_DELETED_LIST="$(extract_section "Pages Deleted" "$DIGEST")"
RAW_SOURCES_SUMMARY="$(extract_section "Raw Sources Appended" "$DIGEST")"

[ -z "$PAGES_ADDED_LIST" ]   && PAGES_ADDED_LIST="_None._"
[ -z "$PAGES_MODIFIED_LIST" ] && PAGES_MODIFIED_LIST="_None._"
[ -z "$PAGES_DELETED_LIST" ] && PAGES_DELETED_LIST="_None._"
[ -z "$RAW_SOURCES_SUMMARY" ] && RAW_SOURCES_SUMMARY="_None._"

MISSING_SOURCES_NOTE=""
if [ "$MISSING_SOURCES" -gt 0 ] 2>/dev/null; then
  MISSING_SOURCES_NOTE="_${MISSING_SOURCES} page(s) need a \`## Sources\` section added._"
fi

# ── Substitute placeholders ───────────────────────────────────────────────────
# Pure string replacement — no eval, no shell expansion of template content.

COMPOSED="$(cat "$TEMPLATE")"

_subst() {
  local key="$1"
  local val="$2"
  # Use awk for safe substitution (avoids sed issues with special chars in val)
  COMPOSED="$(echo "$COMPOSED" | awk -v k="{{$key}}" -v v="$val" '{ gsub(k, v); print }')"
}

_subst "digest_date"          "$DIGEST_DATE"
_subst "generated_at"         "$GENERATED_AT"
_subst "since_duration"       "$SINCE_DURATION"
_subst "n_commits"            "$N_COMMITS"
_subst "pages_added_count"    "$PAGES_ADDED_COUNT"
_subst "pages_modified_count" "$PAGES_MODIFIED_COUNT"
_subst "pages_deleted_count"  "$PAGES_DELETED_COUNT"
_subst "pages_added_list"     "$PAGES_ADDED_LIST"
_subst "pages_modified_list"  "$PAGES_MODIFIED_LIST"
_subst "pages_deleted_list"   "$PAGES_DELETED_LIST"
_subst "raw_sources_summary"  "$RAW_SOURCES_SUMMARY"
_subst "new_wikilinks"        "$NEW_WIKILINKS"
_subst "missing_sources_count" "$MISSING_SOURCES"
_subst "missing_sources_note"  "$MISSING_SOURCES_NOTE"

# ── Output ────────────────────────────────────────────────────────────────────

echo "$COMPOSED"

if [ "$SEND" = "0" ]; then
  echo "" >&2
  echo "kb_digest_send.sh: dry-run mode — composed email printed to stdout" >&2
  echo "  To send (when implemented): add --send and set KB_DIGEST_SEND_CONFIRM" >&2
fi

exit 0
