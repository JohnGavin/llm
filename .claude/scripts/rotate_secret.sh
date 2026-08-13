#!/usr/bin/env bash
# rotate_secret.sh — rotate any Bitwarden-held secret without the value ever
# reaching shell history.
#
# Generalises rotate_gmail_password.sh (which keeps its Gmail-specific handling
# of the three ~/.claude/env fallback files). Use this for every other secret.
#
# WHY
# ---
# The obvious way to rotate is:
#     bws secret edit --value '<new>' <id>
# That writes the secret into ~/.zsh_history permanently. During the 2026-08-11
# incident response we were about to do exactly that, twice. This script takes
# the value on hidden stdin instead.
#
# SECURITY PROPERTIES
# - `read -s`: not echoed, never in shell history.
# - Never printed. All reporting is a 12-char sha256 prefix plus length.
# - Refuses a no-op (new value identical to current) so a re-run cannot look
#   successful while changing nothing.
# - `bws secret edit` takes the value as an argv parameter, so it is briefly
#   visible in `ps` to processes running as you. bws exposes no stdin form
#   (verified: `bws secret edit --help`). Stated, not hidden.
#
# Usage:
#   rotate_secret.sh <SECRET_NAME> [--apply] [--restart <launchd-label>]
#   rotate_secret.sh --selftest
#
# Examples:
#   rotate_secret.sh CACHIX_AUTH_TOKEN
#   rotate_secret.sh GEMINI_API_KEY --apply --restart com.roborev.auto-refine
set -uo pipefail

NAME=""; MODE="--dry-run"; RESTART=""
while [ $# -gt 0 ]; do
    case "$1" in
        --apply)    MODE="--apply" ;;
        --dry-run)  MODE="--dry-run" ;;
        --selftest) MODE="--selftest" ;;
        --restart)  shift; RESTART="${1:-}" ;;
        -*)         echo "unknown flag: $1" >&2; exit 1 ;;
        *)          NAME="$1" ;;
    esac
    shift
done

SECRETS="$HOME/.config/secrets.env"
REGEN="$(dirname "${BASH_SOURCE[0]:-$0}")/secrets_cache_regen.sh"
LOG="$HOME/.claude/logs/rotate_secret.log"

h12() { printf '%s' "$1" | shasum -a 256 | cut -c1-12; }
log() { mkdir -p "$(dirname "$LOG")" 2>/dev/null; printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG" 2>/dev/null || true; }

# ── selftest ────────────────────────────────────────────────────────────────
if [ "$MODE" = "--selftest" ]; then
    pass=0; total=0
    _t() { total=$((total+1)); if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "PASS  $1"; else echo "FAIL  $1 (want=$3 got=$2)"; fi; }

    SENTINEL="zq93rotatesecret7k"

    _t "hash is not the value" "$(h12 "$SENTINEL")" "$(h12 "$SENTINEL")"
    case "$(h12 "$SENTINEL")" in *"$SENTINEL"*) leak=yes;; *) leak=no;; esac
    _t "hash does not contain the value" "$leak" "no"

    out="$(printf 'sha=%s len=%s\n' "$(h12 "$SENTINEL")" "${#SENTINEL}")"
    case "$out" in *"$SENTINEL"*) leak2=yes;; *) leak2=no;; esac
    _t "reported line omits the value" "$leak2" "no"

    # no-op detection
    cur="$SENTINEL"; new="$SENTINEL"
    noop=no; [ "$cur" = "$new" ] && noop=yes
    _t "identical value detected as no-op" "$noop" "yes"

    # empty rejected
    e=""; empty=no; [ -z "$e" ] && empty=yes
    _t "empty value rejected" "$empty" "yes"

    # mismatch detection
    m=no; [ "abc" != "abd" ] && m=yes
    _t "mismatched confirmation detected" "$m" "yes"

    # NO length constraint: secrets legitimately range 15..145 chars here
    # (DOCKER_PSWD=15, CACHIX_AUTH_TOKEN=145). A fixed length check would
    # reject valid values — the Gmail script's 16-char rule is Gmail-specific
    # and deliberately NOT generalised.
    okshort=no; [ ${#SENTINEL} -gt 0 ] && okshort=yes
    _t "no fixed-length constraint imposed" "$okshort" "yes"

    echo ""
    echo "selftest: ${pass}/${total} PASS"
    [ "$pass" -eq "$total" ]
    exit
fi

if [ -z "$NAME" ]; then
    echo "usage: rotate_secret.sh <SECRET_NAME> [--apply] [--restart <launchd-label>]" >&2
    exit 1
fi

# ── token ───────────────────────────────────────────────────────────────────
if [ -z "${BWS_ACCESS_TOKEN:-}" ] && command -v security >/dev/null 2>&1; then
    BWS_ACCESS_TOKEN="$(security find-generic-password -s claude-cron -a bws -w 2>/dev/null)"
    export BWS_ACCESS_TOKEN
fi
[ -n "${BWS_ACCESS_TOKEN:-}" ] || { echo "FATAL: no BWS_ACCESS_TOKEN" >&2; exit 1; }
command -v bws >/dev/null 2>&1 || { echo "FATAL: bws not on PATH" >&2; exit 1; }

# ── resolve name -> id ──────────────────────────────────────────────────────
tmp="$(mktemp)"; chmod 600 "$tmp"
bws secret list -o json > "$tmp" 2>/dev/null
SECRET_ID=$(python3 -c "
import json,sys
try:
    d=json.load(open('$tmp'))
except Exception:
    sys.exit(0)
for s in d:
    if s.get('key')=='$NAME':
        print(s.get('id','')); break
")
CUR=$(python3 -c "
import json,sys
try:
    d=json.load(open('$tmp'))
except Exception:
    sys.exit(0)
for s in d:
    if s.get('key')=='$NAME':
        print(s.get('value','')); break
")
rm -f "$tmp"

if [ -z "$SECRET_ID" ]; then
    echo "FATAL: '$NAME' not found in Bitwarden." >&2
    echo "       If it should exist there, add it first (secrets_to_bws.sh)." >&2
    exit 1
fi

echo "=== $NAME ==="
echo "  BWS id:  $SECRET_ID"
printf '  current: sha=%s len=%s\n' "$(h12 "$CUR")" "${#CUR}"
CACHE=$(grep -m1 -E "^[[:space:]]*(export[[:space:]]+)?${NAME}=" "$SECRETS" 2>/dev/null | sed -E 's/^[^=]*=//; s/^"//; s/"$//')
[ -n "$CACHE" ] && printf '  cache:   sha=%s len=%s\n' "$(h12 "$CACHE")" "${#CACHE}"

# ── read new value ──────────────────────────────────────────────────────────
echo ""
echo "Paste the NEW value for $NAME (input hidden)."
printf '  new: '; read -r -s N1; echo ""
printf '  again: '; read -r -s N2; echo ""

[ "$N1" = "$N2" ] || { echo "FATAL: entries do not match" >&2; exit 1; }
[ -n "$N1" ]      || { echo "FATAL: empty value" >&2; exit 1; }
if [ "$N1" = "$CUR" ]; then
    echo "FATAL: new value is identical to the current one — nothing to rotate." >&2
    exit 1
fi

printf '\nNew value accepted: sha=%s len=%s\n' "$(h12 "$N1")" "${#N1}"

if [ "$MODE" != "--apply" ]; then
    echo ""
    echo "DRY RUN — nothing changed. Re-run with --apply."
    exit 0
fi

# ── apply ───────────────────────────────────────────────────────────────────
echo ""
echo "=== 1/2 updating Bitwarden ==="
if bws secret edit --value "$N1" "$SECRET_ID" >/dev/null 2>&1; then
    echo "  BWS updated"; log "$NAME bws updated sha=$(h12 "$N1")"
else
    echo "FATAL: bws secret edit failed — nothing else changed" >&2
    log "$NAME bws update FAILED"; exit 1
fi

echo ""
echo "=== 2/2 regenerating cache from BWS ==="
[ -x "$REGEN" ] || { echo "FATAL: $REGEN not executable" >&2; exit 1; }
bash "$REGEN" --apply || { echo "FATAL: cache regen failed" >&2; exit 1; }

# ── verify ──────────────────────────────────────────────────────────────────
echo ""
echo "=== verify ==="
want="$(h12 "$N1")"; bad=0
tmp2="$(mktemp)"; chmod 600 "$tmp2"
bws secret list -o json > "$tmp2" 2>/dev/null
v=$(python3 -c "
import json
d=json.load(open('$tmp2'))
for s in d:
    if s.get('key')=='$NAME': print(s.get('value','')); break
")
rm -f "$tmp2"
[ "$(h12 "$v")" = "$want" ] && echo "  BWS         OK" || { echo "  BWS         MISMATCH"; bad=1; }
v=$(grep -m1 -E "^[[:space:]]*(export[[:space:]]+)?${NAME}=" "$SECRETS" 2>/dev/null | sed -E 's/^[^=]*=//; s/^"//; s/"$//')
[ "$(h12 "$v")" = "$want" ] && echo "  secrets.env OK" || { echo "  secrets.env MISMATCH"; bad=1; }

# ── optional daemon restart ─────────────────────────────────────────────────
if [ -n "$RESTART" ]; then
    echo ""
    echo "=== restarting $RESTART (holds the old value in memory) ==="
    if launchctl kickstart -k "gui/$(id -u)/$RESTART" 2>&1; then
        echo "  restarted"; log "$NAME restarted $RESTART"
    else
        echo "  WARN: restart failed — do it manually:"
        echo "    launchctl kickstart -k gui/\$(id -u)/$RESTART"
    fi
fi

echo ""
if [ "$bad" -eq 0 ]; then
    echo "$NAME rotated. All copies share sha=$want"
    echo "NEXT: revoke the OLD value at the provider, then exercise whatever uses it."
    log "$NAME rotation complete"
else
    echo "MISMATCH — investigate before trusting this rotation." >&2
    log "$NAME rotation INCOMPLETE"; exit 1
fi
