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
# MULTI-CONSUMER RESTART + VERIFICATION (llm#955)
# ------------------------------------------------
# A rotated secret is often held in memory by more than one running process
# (e.g. GEMINI_API_KEY is read by both the `com.roborev.auto-refine` launchd
# job AND the self-daemonized `roborev daemon run` process, which is NOT a
# launchd job and cannot be cycled with `launchctl kickstart`). The 2026-08-13
# rotation restarted only the launchd job, reported "restarted" and exited 0,
# while the daemon kept running with the stale value for hours (llm#936) —
# because a KeepAlive launchd job can return success from `kickstart -k`
# without actually cycling, and exit-code-0 was trusted as evidence.
#
# This script never treats "the restart command exited 0" as proof of a
# restart. For every consumer it captures a PID + process start-time BEFORE
# issuing the restart, and again AFTER, and only reports "restarted" when
# BOTH changed. If a consumer's PID cannot be determined, or the restart
# command reports success but the process never cycled, that consumer is
# reported explicitly as unverified/failed and the script exits non-zero —
# per `zero-metric-evidence-or-defect`, "not verified" must never look like
# "verified".
#
# Consumers are declared in the CONSUMERS_<SECRET_NAME> table in
# lib/secret_consumers.sh (shared with rotate_gmail_password.sh, llm#958) as
# space-separated "kind:label" tokens (kind = launchd | daemon). A secret
# with no map entry and no --restart produces an explicit WARNING, not a
# silent no-op — an absent map entry means nobody has yet audited what holds
# that secret in memory, which is different from "nothing does".
#
# Usage:
#   rotate_secret.sh <SECRET_NAME> [--apply] [--restart <spec>[,<spec>...]] [--restart <spec> ...]
#   rotate_secret.sh --selftest
#
# <spec> is a bare launchd label (kind defaults to "launchd") or an explicit
# "kind:label" pair (kind = launchd | daemon). Repeat --restart or pass a
# comma-separated list to name multiple consumers. When --restart is omitted
# entirely, the CONSUMERS_<SECRET_NAME> map in lib/secret_consumers.sh
# supplies the consumer list.
#
# Examples:
#   rotate_secret.sh CACHIX_AUTH_TOKEN
#   rotate_secret.sh GEMINI_API_KEY --apply
#   rotate_secret.sh GEMINI_API_KEY --apply --restart com.roborev.auto-refine --restart daemon:roborev
set -uo pipefail

# ── --restart accumulation (defined before arg parsing so both the CLI loop
#    and --selftest exercise the same code) ──────────────────────────────────
RESTART_LIST=()
add_restart_spec() {
    # Splits a comma-separated value and appends each piece to RESTART_LIST.
    # Called once per --restart flag, so repeated flags accumulate rather
    # than overwrite, and a single flag may still carry a comma-separated list.
    local val="$1"
    local parts=()
    IFS=',' read -r -a parts <<< "$val"
    RESTART_LIST+=("${parts[@]}")
}

NAME=""; MODE="--dry-run"
while [ $# -gt 0 ]; do
    case "$1" in
        --apply)    MODE="--apply" ;;
        --dry-run)  MODE="--dry-run" ;;
        --selftest) MODE="--selftest" ;;
        --restart)
            shift
            val="${1:-}"
            [ -n "$val" ] || { echo "FATAL: --restart requires a value" >&2; exit 1; }
            add_restart_spec "$val"
            ;;
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

# ── consumer map + restart/verify machinery — shared with
#    rotate_gmail_password.sh (llm#958). Defines CONSUMERS_*, kind_get_pid,
#    kind_restart, pid_start_time, CONSUMER_ROWS, restart_and_verify_consumer.
#    Path resolved relative to THIS script's location, not the caller's cwd —
#    both scripts run from arbitrary directories (launchd, cron, interactive).
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SECRET_CONSUMERS_LIB="$SCRIPTS_DIR/lib/secret_consumers.sh"
[ -r "$SECRET_CONSUMERS_LIB" ] || { echo "FATAL: $SECRET_CONSUMERS_LIB not found" >&2; exit 1; }
# shellcheck source=lib/secret_consumers.sh
source "$SECRET_CONSUMERS_LIB"

# ── resolve which consumers to restart: explicit --restart wins, else the map ──
RESOLVED_RESTART_LIST=()
resolve_restart_list() {
    local name="$1"
    RESOLVED_RESTART_LIST=()
    if [ ${#RESTART_LIST[@]} -gt 0 ]; then
        RESOLVED_RESTART_LIST=("${RESTART_LIST[@]}")
        return 0
    fi
    local mapvar="CONSUMERS_${name}"
    local mapval="${!mapvar:-}"
    if [ -n "$mapval" ]; then
        read -r -a RESOLVED_RESTART_LIST <<< "$mapval"
    fi
}

run_consumer_restarts() {
    local name="$1"
    resolve_restart_list "$name"
    if [ ${#RESOLVED_RESTART_LIST[@]} -eq 0 ]; then
        echo "  WARNING: no consumers configured for $name and no --restart given."
        echo "           If a running process holds the old value in memory, restart it manually."
        log "$name rotation: no consumers configured — none restarted"
        return 0
    fi
    local bad=0 spec
    for spec in "${RESOLVED_RESTART_LIST[@]}"; do
        restart_and_verify_consumer "$spec" || bad=1
    done
    return "$bad"
}

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

    # ── llm#958: guard against the consumer map re-duplicating across scripts.
    #    Each CONSUMERS_<NAME> assignment must appear exactly once under
    #    .claude/scripts/** (in lib/secret_consumers.sh). A second copy
    #    re-creates the exact drift risk this dedup was meant to close: add a
    #    consumer to one copy and not the other, and a rotation reports
    #    success while a consumer keeps the old secret. ──────────────────────
    dup_report="$(find "$SCRIPTS_DIR" -name '*.sh' -print0 2>/dev/null \
        | xargs -0 grep -hoE '^CONSUMERS_[A-Za-z0-9_]+=' 2>/dev/null \
        | sort | uniq -c | awk '$1 != 1 {print}')"
    dup_bad=no; [ -n "$dup_report" ] && dup_bad=yes
    _t "each CONSUMERS_* name defined exactly once under scripts/" "$dup_bad" "no"

    # ── llm#955: multi-consumer restart + verification ──────────────────────
    STUBDIR="$(mktemp -d)"
    STUB_STATE_DIR="$(mktemp -d)"
    export STUB_STATE_DIR
    cleanup_stubs() { rm -rf "$STUBDIR" "$STUB_STATE_DIR"; }
    trap cleanup_stubs EXIT

    # stub launchctl: `list <label>` prints a fake PID block read from a state
    # file (created on first read); `kickstart -k gui/<uid>/<label>` bumps the
    # PID in that state file UNLESS the label matches STUB_NOCYCLE_LABEL, and
    # `list <label>` for STUB_MISSING_LABEL reports no PID at all (simulates
    # a job that isn't loaded / can't be found).
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
    [ -f "$pidfile" ] || echo "12340" > "$pidfile"
    printf '{\n\t"PID" = %s;\n\t"Label" = "%s";\n};\n' "$(cat "$pidfile")" "$label"
    ;;
  kickstart)
    ref="${3:-$4}"
    label="${ref##*/}"
    if [ "$label" = "${STUB_NOCYCLE_LABEL:-}" ]; then
      exit 0
    fi
    pidfile="${STUB_STATE_DIR}/${label}.pid"
    old="$(cat "$pidfile" 2>/dev/null || echo 12340)"
    echo "$((old+1))" > "$pidfile"
    ;;
esac
STUB
    chmod +x "$STUBDIR/launchctl"

    # stub ps: `ps -o lstart= -p <pid>` returns a fake timestamp derived from
    # the PID, so a changed PID always implies a changed start-time.
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

    # stub pgrep: `pgrep -f "<label> daemon"` returns a PID from a state file
    # keyed by label, created on first read.
    cat > "$STUBDIR/pgrep" <<'STUB'
#!/usr/bin/env bash
pattern=""; prev=""
for a in "$@"; do
  [ "$prev" = "-f" ] && pattern="$a"
  prev="$a"
done
label="${pattern%% daemon*}"
pidfile="${STUB_STATE_DIR}/daemon-${label}.pid"
[ -f "$pidfile" ] || echo "9000" > "$pidfile"
cat "$pidfile"
STUB
    chmod +x "$STUBDIR/pgrep"

    # stub roborev: `roborev daemon restart` bumps the daemon pidfile.
    cat > "$STUBDIR/roborev" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "daemon" ] && [ "$2" = "restart" ]; then
  pidfile="${STUB_STATE_DIR}/daemon-roborev.pid"
  old="$(cat "$pidfile" 2>/dev/null || echo 9000)"
  echo "$((old+1))" > "$pidfile"
  exit 0
fi
exit 1
STUB
    chmod +x "$STUBDIR/roborev"

    export PATH="$STUBDIR:$PATH"
    export ROTATE_SECRET_RESTART_DELAY=0

    # Case: two consumers, both restart and both verify.
    out_a="$(restart_and_verify_consumer "launchd:com.test.one" 2>&1)"; rc_a=$?
    _t "consumer restarts and verifies (consumer 1)" "$rc_a" "0"
    out_b="$(restart_and_verify_consumer "launchd:com.test.two" 2>&1)"; rc_b=$?
    _t "consumer restarts and verifies (consumer 2)" "$rc_b" "0"

    # Case: a consumer that silently does not cycle (pid/start-time unchanged).
    export STUB_NOCYCLE_LABEL="com.test.stuck"
    out_c="$(restart_and_verify_consumer "launchd:com.test.stuck" 2>&1)"; rc_c=$?
    unset STUB_NOCYCLE_LABEL
    _t "consumer that does not cycle is reported unverified" "$rc_c" "1"
    case "$out_c" in *"DID NOT TAKE EFFECT"*) notcycled=yes;; *) notcycled=no;; esac
    _t "not-cycled consumer message present" "$notcycled" "yes"

    # Case: a consumer whose PID cannot be determined.
    export STUB_MISSING_LABEL="com.test.missing"
    out_d="$(restart_and_verify_consumer "launchd:com.test.missing" 2>&1)"; rc_d=$?
    unset STUB_MISSING_LABEL
    _t "consumer with undeterminable PID is non-zero" "$rc_d" "1"
    case "$out_d" in *"CANNOT VERIFY"*) cvmsg=yes;; *) cvmsg=no;; esac
    _t "cannot-verify message present for missing PID" "$cvmsg" "yes"

    # Case: a secret with no map entry and no --restart -> WARNING, not silent.
    RESTART_LIST=()
    out_e="$(run_consumer_restarts "UNMAPPED_SECRET_ZZZ_NOT_REAL" 2>&1)"; rc_e=$?
    case "$out_e" in *"WARNING"*"no consumers"*) warnmsg=yes;; *) warnmsg=no;; esac
    _t "unmapped secret prints WARNING (not a silent pass)" "$warnmsg" "yes"
    _t "unmapped secret does not fail the run" "$rc_e" "0"

    # Case: a non-launchd daemon: consumer restarts via its own mechanism.
    out_f="$(restart_and_verify_consumer "daemon:roborev" 2>&1)"; rc_f=$?
    _t "daemon consumer restarts via its own mechanism" "$rc_f" "0"
    case "$out_f" in *"restarted and verified"*) dmsg=yes;; *) dmsg=no;; esac
    _t "daemon restart success message present" "$dmsg" "yes"

    # Case: repeated --restart flags accumulate rather than overwrite.
    RESTART_LIST=()
    add_restart_spec "a"
    add_restart_spec "b,c"
    _t "repeated --restart flags accumulate" "${RESTART_LIST[*]}" "a b c"

    trap - EXIT
    cleanup_stubs

    echo ""
    echo "selftest: ${pass}/${total} PASS"
    [ "$pass" -eq "$total" ]
    exit
fi

if [ -z "$NAME" ]; then
    echo "usage: rotate_secret.sh <SECRET_NAME> [--apply] [--restart <spec>[,<spec>...]]" >&2
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

# ── restart & VERIFY consumers (llm#955) ─────────────────────────────────────
echo ""
echo "=== restart & verify consumers ==="
consumer_bad=0
run_consumer_restarts "$NAME" || consumer_bad=1

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
    echo "$NAME rotated. All copies share sha=$want"
    echo "NEXT: revoke the OLD value at the provider, then exercise whatever uses it."
    log "$NAME rotation complete"
else
    [ "$bad" -eq 0 ] || echo "MISMATCH — BWS/cache copies disagree; investigate before trusting this rotation." >&2
    [ "$consumer_bad" -eq 0 ] || echo "CONSUMER RESTART FAILED/UNVERIFIED — see summary above; a process may still hold the old value." >&2
    log "$NAME rotation INCOMPLETE (bad=$bad consumer_bad=$consumer_bad)"
    exit 1
fi
