#!/usr/bin/env bash
# private_values_sync.sh — extract named PII-bearing keys from
# ~/.config/secrets.env into the dedicated deny-list at
# ~/.config/private_values.env, read by private_data_scan.sh.
#
# Why a sync step instead of pointing the scanner at secrets.env directly:
# see private_data_scan.sh's header, "Deny-list source" section, for the
# full rationale (blast radius, schema coupling, wrong shape for the job).
# This script is the single place that bridges the two files, so
# secrets.env stays the one source of truth for the VALUE while
# private_values.env stays narrow and independently permissioned.
#
# This script is NEVER auto-invoked and --apply is NEVER run by an agent
# dispatch (same "MANUAL INSTALL ONLY" convention as
# private_data_git_hooks_install.sh) -- writing to ~/.config/ is a
# user-initiated action.
#
# Usage:
#   private_values_sync.sh --dry-run [--keys KEY1,KEY2,...]
#   private_values_sync.sh --apply   [--keys KEY1,KEY2,...]
#   private_values_sync.sh --selftest
#
# Default --keys: SIGNAL_ACCOUNT (the value JohnGavin/llm#946 flagged as
# embedding a phone number -- "Signal launchd plists are unversioned and
# contain PII"). Pass --keys to sync additional named PII-bearing keys as
# they are identified; this script does not guess which keys in
# secrets.env are PII -- only named keys the user opts in are ever synced.
#
# Output file: ~/.config/private_values.env, mode 600, KEY=value lines,
# each carrying a comment noting its source key and sync timestamp.
# Existing manually-added entries (no "# synced from secrets.env" marker)
# are PRESERVED across re-runs -- this script only ever adds/updates its
# own synced block, never touches lines it did not write.

set -uo pipefail

SECRETS_ENV_FILE="${SECRETS_ENV_FILE:-$HOME/.config/secrets.env}"
PRIVATE_VALUES_FILE="${PRIVATE_VALUES_FILE:-$HOME/.config/private_values.env}"
SYNC_MARKER="# synced from secrets.env by private_values_sync.sh"

MODE=""
KEYS="SIGNAL_ACCOUNT"
SELFTEST=0

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) MODE="dry-run"; shift ;;
        --apply) MODE="apply"; shift ;;
        --keys) shift; KEYS="${1:-$KEYS}"; shift || true ;;
        --selftest) SELFTEST=1; shift ;;
        -h|--help) echo "Usage: private_values_sync.sh --dry-run|--apply [--keys K1,K2] | --selftest"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done

# sync_one SECRETS_FILE PRIVATE_FILE KEYS_CSV MODE -> prints what changed
sync_one() {
    local secrets_file="$1" private_file="$2" keys_csv="$3" mode="$4"
    if [ ! -r "$secrets_file" ]; then
        echo "  $secrets_file not readable -- nothing to sync." >&2
        return 1
    fi

    local key val
    local -a lines=()
    IFS=',' read -ra key_list <<< "$keys_csv"
    for key in "${key_list[@]}"; do
        [ -n "$key" ] || continue
        val="$(
            set -a
            # shellcheck disable=SC1090
            . "$secrets_file"
            set +a
            eval "printf '%s' \"\${${key}:-}\""
        )"
        if [ -z "$val" ]; then
            echo "  $key: not set in $secrets_file -- skipped"
            continue
        fi
        echo "  $key: found (value not shown) -- would sync"
        lines+=("${SYNC_MARKER} (${key}, $(date -u +%Y-%m-%dT%H:%M:%SZ))")
        lines+=("${key}=${val}")
    done

    if [ "${#lines[@]}" -eq 0 ]; then
        echo "  Nothing to sync."
        return 0
    fi

    if [ "$mode" = "dry-run" ]; then
        echo "  [dry-run] would write ${#lines[@]} line(s) into $private_file (values not shown here either)"
        return 0
    fi

    # Preserve any existing content that is NOT part of a previous synced
    # block from THIS script (manual entries), then append the fresh sync.
    local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/private_values_sync.XXXXXX")"
    if [ -f "$private_file" ]; then
        # Each synced entry is exactly 2 lines: the marker line, then the
        # KEY=value line. skip=1 means "skip exactly one MORE line after
        # this marker" (the marker line itself is already dropped by the
        # `next` in the first rule) -- skip=2 here would drop 3 lines total
        # (marker + KEY=value + the line AFTER it), silently eating the
        # next real entry. Caught by this script's own selftest.
        awk -v marker="$SYNC_MARKER" '
            BEGIN { skip = 0 }
            index($0, marker) == 1 { skip = 1; next }
            skip > 0 { skip--; next }
            { print }
        ' "$private_file" > "$tmp"
    fi
    {
        cat "$tmp" 2>/dev/null
        printf '%s\n' "${lines[@]}"
    } > "$private_file"
    chmod 600 "$private_file"
    rm -f "$tmp"
    echo "  Wrote $private_file (mode 600)."
}

if [ "$SELFTEST" -eq 1 ]; then
    pass=0; total=0
    _check() { total=$((total + 1)); if [ "$1" = "0" ]; then pass=$((pass + 1)); echo "PASS  $2"; else echo "FAIL  $2"; fi; }

    tmp="$(mktemp -d "${TMPDIR:-/tmp}/pvs_selftest.XXXXXX")"
    printf 'SIGNAL_ACCOUNT=+19998887766\nOTHER_SECRET=notpii\n' > "$tmp/secrets.env"
    chmod 600 "$tmp/secrets.env"
    priv="$tmp/private_values.env"

    # 1: dry-run writes nothing
    out="$(sync_one "$tmp/secrets.env" "$priv" "SIGNAL_ACCOUNT" "dry-run" 2>&1)"
    if [ -f "$priv" ]; then _check 1 "dry-run must not create the private values file"; else _check 0 "dry-run creates no file"; fi
    case "$out" in *"+19998887766"*) _check 1 "REGRESSION: dry-run output leaked the actual value" ;; *) _check 0 "dry-run output never shows the actual value" ;; esac

    # 2: apply writes the file with correct KEY=value and mode 600
    sync_one "$tmp/secrets.env" "$priv" "SIGNAL_ACCOUNT" "apply" >/dev/null 2>&1
    if grep -qF "SIGNAL_ACCOUNT=+19998887766" "$priv" 2>/dev/null; then
        _check 0 "apply writes the correct KEY=value line"
    else
        _check 1 "apply did not write the expected line"
    fi
    m="$(stat -f '%Lp' "$priv" 2>/dev/null || stat -c '%a' "$priv" 2>/dev/null)"
    [ "$m" = "600" ] && _check 0 "written file has mode 600" || _check 1 "written file mode is $m, expected 600"

    # 3: a manually-added entry survives re-sync
    printf 'HOME_ADDRESS=1 Example Street\n' >> "$priv"
    sync_one "$tmp/secrets.env" "$priv" "SIGNAL_ACCOUNT" "apply" >/dev/null 2>&1
    if grep -qF "HOME_ADDRESS=1 Example Street" "$priv" 2>/dev/null; then
        _check 0 "manually-added entries survive a re-sync"
    else
        _check 1 "re-sync destroyed a manually-added entry"
    fi
    if [ "$(grep -cF 'SIGNAL_ACCOUNT=' "$priv")" -eq 1 ]; then
        _check 0 "re-sync does not duplicate the synced key"
    else
        _check 1 "re-sync duplicated the synced key"
    fi

    # 4: missing key is skipped, not fatal
    out="$(sync_one "$tmp/secrets.env" "$priv" "NOT_A_REAL_KEY" "apply" 2>&1)"
    case "$out" in *"skipped"*) _check 0 "a key absent from secrets.env is skipped, not fatal" ;; *) _check 1 "missing key was not handled gracefully" ;; esac

    # 5: unreadable secrets file fails, does not crash
    set +e
    sync_one "$tmp/does_not_exist.env" "$priv" "SIGNAL_ACCOUNT" "apply" >/dev/null 2>&1
    rc=$?
    set -e
    [ "$rc" -ne 0 ] && _check 0 "missing secrets.env returns non-zero" || _check 1 "missing secrets.env should return non-zero"

    rm -rf "$tmp"
    echo ""
    echo "private_values_sync selftest: $pass/$total PASS"
    [ "$pass" -eq "$total" ] && exit 0
    exit 1
fi

if [ -z "$MODE" ]; then
    echo "ERROR: --dry-run or --apply is required" >&2
    exit 1
fi

echo "private_values_sync: ${MODE} (keys=${KEYS})"
sync_one "$SECRETS_ENV_FILE" "$PRIVATE_VALUES_FILE" "$KEYS" "$MODE"
