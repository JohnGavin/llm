#!/usr/bin/env bash
# rotate_gmail_password.sh — rotate GMAIL_APP_PASSWORD everywhere, in one pass.
#
# WHY THIS EXISTS
# ---------------
# As of 2026-08-13 the Gmail app password existed in three places with THREE
# DIFFERENT VALUES: a 21-char corrupted variant in ~/.config/secrets.env (a bad
# append with no trailing newline glued FRED_API_KEY onto it), a 16-char value
# in the three ~/.claude/env/*.env fallback files, and a DIFFERENT 16-char
# value in Bitwarden. Six launchd email jobs read some combination of these.
# Rotating by hand across that many copies is how a partial rotation happens
# and then fails silently days later.
#
# This script makes every copy demonstrably current in one operation, and never
# lets the new value reach shell history.
#
# WHAT IT DOES NOT DO
# -------------------
# It does not talk to Google. Generate the new app password yourself first at
#   https://myaccount.google.com/apppasswords
# (Google's own docs give that URL and deliberately document no menu path.)
# Note from those docs: changing your main Google account password revokes all
# app passwords — so if you plan to rotate both, do the ACCOUNT password FIRST,
# then generate the app password, then run this.
#
# SECURITY PROPERTIES
# -------------------
# - The value is read with `read -s`: not echoed, never in ~/.zsh_history.
# - It is never printed. Verification is by 12-char sha256 prefix and length.
# - `bws secret edit` takes the value as an argv parameter, so it IS briefly
#   visible in `ps` to processes running as you. bws offers no stdin form
#   (checked `bws secret edit --help`). That exposure is local, transient, and
#   unavoidable with this tool — stated here rather than hidden.
#
# Usage:
#   rotate_gmail_password.sh --dry-run   (default) — validate, change nothing
#   rotate_gmail_password.sh --apply
#   rotate_gmail_password.sh --selftest
set -uo pipefail

MODE="${1:---dry-run}"

BWS_SECRET_ID="${BWS_GMAIL_SECRET_ID:-be3edaf9-ea64-4ec6-a57c-b469013af5a8}"
SECRETS="$HOME/.config/secrets.env"
ENV_FILES=(
    "$HOME/.claude/env/overnight_self_review.env"
    "$HOME/.claude/env/kb_digest.env"
    "$HOME/.claude/env/roborev_email.env"
)
REGEN="$(dirname "${BASH_SOURCE[0]:-$0}")/secrets_cache_regen.sh"
LOG="$HOME/.claude/logs/rotate_gmail_password.log"

h12() { printf '%s' "$1" | shasum -a 256 | cut -c1-12; }
log() { mkdir -p "$(dirname "$LOG")" 2>/dev/null; printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG" 2>/dev/null || true; }

# ── selftest ────────────────────────────────────────────────────────────────
if [ "$MODE" = "--selftest" ]; then
    pass=0; total=0
    _t() { total=$((total+1)); if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "PASS  $1"; else echo "FAIL  $1 (want=$3 got=$2)"; fi; }

    # strip_spaces behaves as Google's 16-digit-with-spaces format requires
    v="abcd efgh ijkl mnop"
    stripped="${v// /}"
    _t "spaces stripped from Google's display form" "${#stripped}" "16"

    # a 16-char all-lowercase password (no digits) must be accepted:
    # this is the real Gmail shape and a naive "must contain a digit" check
    # would reject exactly the credential we are rotating.
    v2="lriqpykiwgdszybg"
    ok="no"; [ "${#v2}" -eq 16 ] && ok="yes"
    _t "16-char all-lowercase accepted (no digit requirement)" "$ok" "yes"

    # wrong length rejected
    v3="tooshort"
    ok2="no"; [ "${#v3}" -ne 16 ] && ok2="yes"
    _t "non-16-char rejected" "$ok2" "yes"

    # hashing never returns the input
    hv="$(h12 "$v2")"
    same="no"; [ "$hv" = "$v2" ] && same="yes"
    _t "hash is not the value" "$same" "no"

    # sentinel never appears in this script's own output
    out="$(printf 'len=%s sha=%s\n' "${#v2}" "$hv")"
    case "$out" in *"$v2"*) leak="yes";; *) leak="no";; esac
    _t "sentinel absent from reported output" "$leak" "no"

    echo ""
    echo "selftest: ${pass}/${total} PASS"
    [ "$pass" -eq "$total" ]
    exit
fi

# ── pre-flight ──────────────────────────────────────────────────────────────
if [ -z "${BWS_ACCESS_TOKEN:-}" ]; then
    if command -v security >/dev/null 2>&1; then
        BWS_ACCESS_TOKEN="$(security find-generic-password -s claude-cron -a bws -w 2>/dev/null)"
        export BWS_ACCESS_TOKEN
    fi
fi
if [ -z "${BWS_ACCESS_TOKEN:-}" ]; then
    echo "FATAL: no BWS_ACCESS_TOKEN (not in env, not in Keychain service=claude-cron account=bws)" >&2
    exit 1
fi
command -v bws >/dev/null 2>&1 || { echo "FATAL: bws not on PATH" >&2; exit 1; }

echo "=== current state (hashes only, never values) ==="
cur_bws=$(bws secret get "$BWS_SECRET_ID" -o json 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin).get("value",""))' 2>/dev/null)
[ -n "$cur_bws" ] && printf '  BWS                 sha=%s len=%s\n' "$(h12 "$cur_bws")" "${#cur_bws}" \
                  || echo "  BWS                 UNREADABLE — check token/permissions"
cur_cache=$(grep -m1 -E '^[[:space:]]*(export[[:space:]]+)?GMAIL_APP_PASSWORD=' "$SECRETS" 2>/dev/null | sed -E 's/^[^=]*=//; s/^"//; s/"$//')
[ -n "$cur_cache" ] && printf '  secrets.env (cache) sha=%s len=%s\n' "$(h12 "$cur_cache")" "${#cur_cache}"
for f in "${ENV_FILES[@]}"; do
    v=$(grep -m1 -E '^[[:space:]]*(export[[:space:]]+)?GMAIL_APP_PASSWORD=' "$f" 2>/dev/null | sed -E 's/^[^=]*=//; s/^"//; s/"$//')
    [ -n "$v" ] && printf '  %-20s sha=%s len=%s\n' "$(basename "$f")" "$(h12 "$v")" "${#v}"
done

# ── read the new value ──────────────────────────────────────────────────────
echo ""
echo "Paste the NEW Gmail app password (input hidden; spaces are stripped)."
printf '  new password: '
read -r -s NEW1
echo ""
printf '  again to confirm: '
read -r -s NEW2
echo ""

NEW1="${NEW1// /}"; NEW2="${NEW2// /}"

if [ "$NEW1" != "$NEW2" ]; then echo "FATAL: entries do not match" >&2; exit 1; fi
if [ -z "$NEW1" ]; then echo "FATAL: empty" >&2; exit 1; fi
if [ "${#NEW1}" -ne 16 ]; then
    echo "FATAL: expected 16 characters after stripping spaces, got ${#NEW1}." >&2
    echo "       Google app passwords are 16 characters, displayed in 4 groups of 4." >&2
    exit 1
fi
if [ -n "$cur_bws" ] && [ "$NEW1" = "$cur_bws" ]; then
    echo "FATAL: new value is identical to the current BWS value — nothing to rotate." >&2
    exit 1
fi

echo ""
printf 'New value accepted: sha=%s len=%s\n' "$(h12 "$NEW1")" "${#NEW1}"

if [ "$MODE" != "--apply" ]; then
    echo ""
    echo "DRY RUN — nothing changed. Re-run with --apply."
    exit 0
fi

# ── 1. Bitwarden (system of record) ─────────────────────────────────────────
echo ""
echo "=== 1/3 updating Bitwarden (system of record) ==="
if bws secret edit --value "$NEW1" "$BWS_SECRET_ID" >/dev/null 2>&1; then
    echo "  BWS updated"
    log "bws updated sha=$(h12 "$NEW1")"
else
    echo "FATAL: bws secret edit failed — nothing else changed" >&2
    log "bws update FAILED"
    exit 1
fi

# ── 2. regenerate the cache from BWS ────────────────────────────────────────
echo ""
echo "=== 2/3 regenerating ~/.config/secrets.env from BWS ==="
if [ -x "$REGEN" ]; then
    bash "$REGEN" --apply || { echo "FATAL: cache regen failed" >&2; exit 1; }
else
    echo "FATAL: $REGEN not found/executable" >&2; exit 1
fi

# ── 3. the fallback files ───────────────────────────────────────────────────
echo ""
echo "=== 3/3 updating ~/.claude/env fallback files ==="
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
for f in "${ENV_FILES[@]}"; do
    [ -r "$f" ] || { echo "  skip (absent): $f"; continue; }
    cp -a "$f" "$f.bak-$stamp"
    chmod 600 "$f.bak-$stamp" 2>/dev/null || true
    tmp="$(mktemp)"; chmod 600 "$tmp"
    awk -v newv="$NEW1" '
      /^[[:space:]]*(export[[:space:]]+)?GMAIL_APP_PASSWORD=/ {
        if ($0 ~ /^[[:space:]]*export/) print "export GMAIL_APP_PASSWORD=\"" newv "\""
        else                             print "GMAIL_APP_PASSWORD=\"" newv "\""
        next
      }
      { print }
    ' "$f" > "$tmp"
    mv "$tmp" "$f"; chmod 600 "$f"
    echo "  updated $(basename "$f")  (backup: $(basename "$f").bak-$stamp)"
done
log "fallback files updated"

# ── verify ──────────────────────────────────────────────────────────────────
echo ""
echo "=== verify: every copy should now share one hash ==="
want="$(h12 "$NEW1")"
bad=0
v=$(bws secret get "$BWS_SECRET_ID" -o json 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin).get("value",""))' 2>/dev/null)
[ "$(h12 "$v")" = "$want" ] && echo "  BWS                 OK" || { echo "  BWS                 MISMATCH"; bad=1; }
v=$(grep -m1 -E '^[[:space:]]*(export[[:space:]]+)?GMAIL_APP_PASSWORD=' "$SECRETS" 2>/dev/null | sed -E 's/^[^=]*=//; s/^"//; s/"$//')
[ "$(h12 "$v")" = "$want" ] && echo "  secrets.env         OK" || { echo "  secrets.env         MISMATCH"; bad=1; }
for f in "${ENV_FILES[@]}"; do
    [ -r "$f" ] || continue
    v=$(grep -m1 -E '^[[:space:]]*(export[[:space:]]+)?GMAIL_APP_PASSWORD=' "$f" 2>/dev/null | sed -E 's/^[^=]*=//; s/^"//; s/"$//')
    [ "$(h12 "$v")" = "$want" ] && printf '  %-20s OK\n' "$(basename "$f")" || { printf '  %-20s MISMATCH\n' "$(basename "$f")"; bad=1; }
done

echo ""
if [ "$bad" -eq 0 ]; then
    echo "All copies now share sha=$want"
    echo ""
    echo "NEXT: live-test one email job, e.g."
    echo "  bash ~/docs_gh/llm/bin/overnight_self_review_email_cron.sh"
    echo "Then delete the .bak files once it succeeds."
    log "rotation complete sha=$want"
else
    echo "ONE OR MORE COPIES MISMATCH — investigate before trusting the rotation." >&2
    log "rotation INCOMPLETE"
    exit 1
fi
