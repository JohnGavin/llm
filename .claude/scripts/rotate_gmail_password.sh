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
# MULTI-CONSUMER RESTART + VERIFICATION (llm#955)
# ------------------------------------------------
# rotate_secret.sh (the generic sibling of this script) was found to report a
# false success: it restarted one launchd consumer of a secret, exited 0, and
# left a second, non-launchd consumer holding the stale value for hours
# (llm#936). This script has the same weakness — it never restarted anything,
# it only told the caller to go test a job by hand. Rather than sourcing
# rotate_secret.sh's restart machinery (this dispatch's write-scope is this
# file, rotate_secret.sh, and the rules doc only — no new shared-lib file), the
# same consumer-map + verify-by-PID-and-start-time design is duplicated below.
# GMAIL_APP_PASSWORD's consumers are all launchd jobs (no self-daemonized
# process reads it), so only the `launchd:` kind is exercised here, but the
# same `kind:label` shape is kept for consistency with rotate_secret.sh.
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

# ── consumers of GMAIL_APP_PASSWORD — every launchd job that reads it via
#    the ~/.claude/env fallback files above. Restarted + VERIFIED after every
#    rotation (llm#955): a consumer NOT listed here is invisible to this
#    check, so keep this list in sync with the ENV_FILES readers. ───────────
CONSUMERS_GMAIL_APP_PASSWORD="launchd:com.claude.overnight-self-review-email launchd:com.claude.kb-digest-email launchd:com.claude.config-digest-email launchd:com.claude.roborev-daily-email launchd:com.claude.roborev-weekly-rollup-email"

# ── consumer restart mechanisms — table-driven: a new kind is one `case` arm
#    in each of the three functions below, not a new code path. Duplicated
#    from rotate_secret.sh (see the MULTI-CONSUMER header comment above for
#    why this is a duplication rather than a shared import). ────────────────
kind_get_pid() {
    case "$1" in
        launchd)
            launchctl list "$2" 2>/dev/null \
              | awk -F'= ' '/"PID"/{gsub(/[; \t]/,"",$2); print $2; exit}'
            ;;
        daemon)
            pgrep -f "$2 daemon" 2>/dev/null | head -1
            ;;
        *) return 1 ;;
    esac
}

kind_restart() {
    case "$1" in
        launchd) launchctl kickstart -k "gui/$(id -u)/$2" >/dev/null 2>&1 ;;
        daemon)  "$2" daemon restart >/dev/null 2>&1 ;;
        *)       return 1 ;;
    esac
}

pid_start_time() {
    local pid="$1"
    [ -n "$pid" ] || return 1
    ps -o lstart= -p "$pid" 2>/dev/null | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

# Never treats "restart command exited 0" as proof. Captures PID + process
# start-time before and after; only reports success when both changed.
CONSUMER_ROWS=()

restart_and_verify_consumer() {
    local spec="$1" kind label pid_before pid_after t_before t_after
    if [[ "$spec" == *:* ]]; then
        kind="${spec%%:*}"; label="${spec#*:}"
    else
        kind="launchd"; label="$spec"
    fi

    case "$kind" in
        launchd|daemon) : ;;
        *)
            echo "  $spec  UNKNOWN CONSUMER KIND '$kind' — skipping"
            CONSUMER_ROWS+=("$spec|$kind|no|no|unknown-kind")
            return 1
            ;;
    esac

    pid_before="$(kind_get_pid "$kind" "$label")"
    if [ -z "$pid_before" ]; then
        echo "  $spec  CANNOT VERIFY — no running process found before restart"
        CONSUMER_ROWS+=("$spec|$kind|no|no|cannot-determine-pid")
        return 1
    fi
    t_before="$(pid_start_time "$pid_before")"

    if ! kind_restart "$kind" "$label"; then
        echo "  $spec  RESTART COMMAND FAILED"
        CONSUMER_ROWS+=("$spec|$kind|no|no|restart-command-failed")
        return 1
    fi

    sleep "${ROTATE_SECRET_RESTART_DELAY:-2}"

    pid_after="$(kind_get_pid "$kind" "$label")"
    if [ -z "$pid_after" ]; then
        echo "  $spec  CANNOT VERIFY — no running process found after restart"
        CONSUMER_ROWS+=("$spec|$kind|yes|no|cannot-determine-pid-after")
        return 1
    fi
    t_after="$(pid_start_time "$pid_after")"

    if [ "$pid_before" = "$pid_after" ] && [ "$t_before" = "$t_after" ]; then
        echo "  $spec  RESTART DID NOT TAKE EFFECT — pid+start-time unchanged (pid=$pid_before, start=$t_before)"
        CONSUMER_ROWS+=("$spec|$kind|yes|no|not-cycled")
        return 1
    fi

    echo "  $spec  restarted and verified (pid $pid_before -> $pid_after)"
    CONSUMER_ROWS+=("$spec|$kind|yes|yes|ok")
    return 0
}

run_consumer_restarts() {
    local name="$1"
    local mapvar="CONSUMERS_${name}"
    local mapval="${!mapvar:-}"
    local list=()
    if [ -n "$mapval" ]; then
        read -r -a list <<< "$mapval"
    fi
    if [ ${#list[@]} -eq 0 ]; then
        echo "  WARNING: no consumers configured for $name."
        echo "           If a running process holds the old value in memory, restart it manually."
        log "$name rotation: no consumers configured — none restarted"
        return 0
    fi
    local bad=0 spec
    for spec in "${list[@]}"; do
        restart_and_verify_consumer "$spec" || bad=1
    done
    return "$bad"
}

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

    # ── llm#955: multi-consumer restart + verification ──────────────────────
    STUBDIR="$(mktemp -d)"
    STUB_STATE_DIR="$(mktemp -d)"
    export STUB_STATE_DIR
    cleanup_stubs() { rm -rf "$STUBDIR" "$STUB_STATE_DIR"; }
    trap cleanup_stubs EXIT

    # stub launchctl: `list <label>` prints a fake PID block read from a state
    # file (created on first read); `kickstart -k gui/<uid>/<label>` bumps the
    # PID UNLESS the label matches STUB_NOCYCLE_LABEL; `list <label>` for
    # STUB_MISSING_LABEL reports no PID at all (job not loaded).
    cat > "$STUBDIR/launchctl" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  list)
    label="$2"
    if [ "$label" = "${STUB_MISSING_LABEL:-}" ]; then
      echo "Could not find service \"$label\"" >&2
      exit 1
    fi
    pidfile="${STUB_STATE_DIR}/${label}.pid"
    [ -f "$pidfile" ] || echo "5550" > "$pidfile"
    printf '{\n\t"PID" = %s;\n\t"Label" = "%s";\n};\n' "$(cat "$pidfile")" "$label"
    ;;
  kickstart)
    ref="${3:-$4}"
    label="${ref##*/}"
    if [ "$label" = "${STUB_NOCYCLE_LABEL:-}" ]; then
      exit 0
    fi
    pidfile="${STUB_STATE_DIR}/${label}.pid"
    old="$(cat "$pidfile" 2>/dev/null || echo 5550)"
    echo "$((old+1))" > "$pidfile"
    ;;
esac
STUB
    chmod +x "$STUBDIR/launchctl"

    cat > "$STUBDIR/ps" <<'STUB'
#!/usr/bin/env bash
pid=""; prev=""
for a in "$@"; do
  [ "$prev" = "-p" ] && pid="$a"
  prev="$a"
done
echo "faketime-$pid"
STUB
    chmod +x "$STUBDIR/ps"

    export PATH="$STUBDIR:$PATH"
    export ROTATE_SECRET_RESTART_DELAY=0

    out_g="$(restart_and_verify_consumer "launchd:com.claude.overnight-self-review-email" 2>&1)"; rc_g=$?
    _t "consumer restarts and verifies" "$rc_g" "0"

    export STUB_NOCYCLE_LABEL="com.claude.kb-digest-email"
    out_h="$(restart_and_verify_consumer "launchd:com.claude.kb-digest-email" 2>&1)"; rc_h=$?
    unset STUB_NOCYCLE_LABEL
    _t "consumer that does not cycle is reported unverified (non-zero)" "$rc_h" "1"
    case "$out_h" in *"DID NOT TAKE EFFECT"*) notcycled=yes;; *) notcycled=no;; esac
    _t "not-cycled consumer message present" "$notcycled" "yes"

    export STUB_MISSING_LABEL="com.claude.config-digest-email"
    out_i="$(restart_and_verify_consumer "launchd:com.claude.config-digest-email" 2>&1)"; rc_i=$?
    unset STUB_MISSING_LABEL
    _t "consumer with undeterminable PID is non-zero" "$rc_i" "1"
    case "$out_i" in *"CANNOT VERIFY"*) cvmsg=yes;; *) cvmsg=no;; esac
    _t "cannot-verify message present for missing PID" "$cvmsg" "yes"

    trap - EXIT
    cleanup_stubs

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

# ── restart & VERIFY consumers (llm#955) ─────────────────────────────────────
echo ""
echo "=== restart & verify consumers ==="
consumer_bad=0
run_consumer_restarts "GMAIL_APP_PASSWORD" || consumer_bad=1

if [ ${#CONSUMER_ROWS[@]} -gt 0 ]; then
    echo ""
    echo "=== consumer restart summary ==="
    printf '  %-50s %-8s %-10s %-9s %s\n' "CONSUMER" "KIND" "RESTARTED" "VERIFIED" "NOTE"
    for row in "${CONSUMER_ROWS[@]}"; do
        IFS='|' read -r c_spec c_kind c_restarted c_verified c_note <<< "$row"
        printf '  %-50s %-8s %-10s %-9s %s\n' "$c_spec" "$c_kind" "$c_restarted" "$c_verified" "$c_note"
    done
fi

echo ""
if [ "$bad" -eq 0 ] && [ "$consumer_bad" -eq 0 ]; then
    echo "All copies now share sha=$want"
    echo ""
    echo "NEXT: delete the .bak files once you've confirmed the jobs above are healthy."
    log "rotation complete sha=$want"
else
    [ "$bad" -eq 0 ] || echo "ONE OR MORE COPIES MISMATCH — investigate before trusting the rotation." >&2
    [ "$consumer_bad" -eq 0 ] || echo "CONSUMER RESTART FAILED/UNVERIFIED — see summary above; a process may still hold the old value." >&2
    log "rotation INCOMPLETE (bad=$bad consumer_bad=$consumer_bad)"
    exit 1
fi
