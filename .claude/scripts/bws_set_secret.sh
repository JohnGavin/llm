#!/usr/bin/env bash
# bws_set_secret.sh — create or update a Bitwarden Secrets Manager secret
# without the value ever reaching argv, shell history, or a terminal.
#
# WHY THIS EXISTS
# ---------------
# `bws secret create <KEY> <VALUE> <PROJECT_ID>` takes the value as a positional
# argument. That means:
#   • it is visible in `ps` to any process running as you, for the call's life
#   • it lands in shell history unless HIST_IGNORE_SPACE happens to be on
#   • it invites a copy-paste template with a <placeholder> in it
#
# The third is not hypothetical. On 2026-08-25 a documented one-liner containing
# a literal `'<cachix-token>'` placeholder was pasted and run verbatim, and BWS
# faithfully stored the eleven characters `<cachix-token>` as the value of
# CACHIX_AUTH_TOKEN. No error: the command was valid, the value was wrong, and
# nothing downstream could tell the difference. A prompt cannot be pasted past.
#
# `rotate_secret.sh` already does hidden-stdin correctly but is UPDATE-ONLY —
# it exits "not found in Bitwarden" for a secret that does not exist yet. This
# script covers the create case and the correct-a-bad-value case, then hands
# off to the same cache regeneration.
#
# SECURITY PROPERTIES
#   • `read -rs`: value never echoed, never in history, never in argv from the
#     caller's side.
#   • Typed twice and compared; refuses on mismatch.
#   • Refuses obvious placeholder shapes (<...>, YOUR_..., xxx, changeme).
#   • Reports only a 12-char sha256 prefix and a length — never the value.
#   • Refuses a no-op (new value identical to current) so a re-run cannot look
#     successful while changing nothing.
#   • BWS_ACCESS_TOKEN is read from the macOS Keychain (service=claude-cron,
#     account=bws), the same source bws_launcher.sh uses. Never from a shell
#     variable — those do not reliably propagate to child processes.
#
# KNOWN RESIDUAL RISK, stated not hidden: `bws` itself takes --value on argv, so
# the value is briefly visible in `ps` for the duration of that one call. bws
# exposes no stdin form (verified: `bws secret create --help`, `bws secret edit
# --help`, v2.1.0). This script removes every other exposure; it cannot remove
# that one.
#
# Usage:
#   bws_set_secret.sh <SECRET_NAME> [--project-id <ID>] [--no-regen]
#   bws_set_secret.sh --selftest
#
# Exit: 0 ok · 1 refused/failed · 2 usage
#
# llm#1013, llm#1022

set -uo pipefail

BWS_BIN="${BWS_BIN:-$HOME/.cargo/bin/bws}"
KEYCHAIN_SERVICE="${BWS_KEYCHAIN_SERVICE:-claude-cron}"
KEYCHAIN_ACCOUNT="${BWS_KEYCHAIN_ACCOUNT:-bws}"
REGEN="${BWS_REGEN_SCRIPT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/secrets_cache_regen.sh}"
LOG="${BWS_SET_LOG:-$HOME/.claude/logs/bws_set_secret.log}"

NAME=""
PROJECT_ID=""
DO_REGEN=1
VERIFY_CMD=""
NO_VERIFY=0

# Ground-truth verifiers, keyed by secret name (llm#1026).
_SGT_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/secret_ground_truth.sh"
# shellcheck source=lib/secret_ground_truth.sh
[ -r "$_SGT_LIB" ] && . "$_SGT_LIB"

log() { mkdir -p "$(dirname "$LOG")" 2>/dev/null; printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG"; }

usage() {
    cat >&2 <<'USAGE'
Usage: bws_set_secret.sh <SECRET_NAME> [options]
       bws_set_secret.sh --selftest

  --project-id <ID>      project for a CREATE (derived from an existing secret otherwise)
  --no-regen             skip regenerating ~/.config/secrets.env
  --verify-against <CMD> compare the typed value against CMD's stdout (digests only)
  --no-verify            skip a built-in ground-truth check for this secret

Some secrets have a known authority on this machine (see
lib/secret_ground_truth.sh) and are verified automatically. Double entry
catches a slip; it cannot catch a misreading, because the same typo typed
twice is self-consistent.
USAGE
    exit 2
}

# ── Value hygiene ────────────────────────────────────────────────────────────

# Digest for reporting. Never prints the value itself.
_digest() { printf '%s' "$1" | shasum -a 256 | cut -c1-12; }

# Reject values that are obviously a template, not a secret. This is the check
# that would have stopped the 2026-08-25 incident.
_looks_like_placeholder() {
    local v="$1"
    case "$v" in
        ('<'*'>')                      return 0 ;;   # <cachix-token>
        (*'YOUR_'*|*'your-'*)          return 0 ;;
        ('xxx'*|'XXX'*|'changeme'*)    return 0 ;;
        ('...'*|*'...')                return 0 ;;
        ('TODO'*|'FIXME'*)             return 0 ;;
    esac
    # A real token is not three characters long.
    [ "${#v}" -lt 8 ] && return 0
    return 1
}

# ── BWS plumbing ─────────────────────────────────────────────────────────────

_keychain_token() {
    security find-generic-password -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null
}

# Print the JSON for all secrets. Distinguishes "call failed" (rc 2) from
# "call succeeded, no secrets" (rc 0, empty array) — per the
# checks-must-distinguish-unknown rule.
_secret_list_json() {
    local tok out rc
    tok="$(_keychain_token)"
    if [ -z "$tok" ]; then
        echo "FATAL: no BWS access token in Keychain (service=$KEYCHAIN_SERVICE account=$KEYCHAIN_ACCOUNT)" >&2
        return 2
    fi
    out="$(BWS_ACCESS_TOKEN="$tok" "$BWS_BIN" secret list -o json 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "FATAL: bws secret list failed (rc=$rc): $(printf '%s' "$out" | head -c 200)" >&2
        return 2
    fi
    printf '%s' "$out"
}

# Given the list JSON and a key name, print "<id>\t<sha12-of-value>" or nothing.
_find_secret() {
    printf '%s' "$1" | NAME="$2" python3 -c '
import json, sys, os, hashlib
name = os.environ["NAME"]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for s in data if isinstance(data, list) else []:
    if s.get("key") == name:
        v = s.get("value") or ""
        print(s.get("id","") + "\t" + hashlib.sha256(v.encode()).hexdigest()[:12])
        break
'
}

# ── Main flow ────────────────────────────────────────────────────────────────

run_set() {
    [ -x "$BWS_BIN" ] || { echo "FATAL: bws not executable at $BWS_BIN" >&2; return 1; }

    local list_json rc
    list_json="$(_secret_list_json)"; rc=$?
    [ "$rc" -eq 0 ] || return 1

    local existing id old_sha
    existing="$(_find_secret "$list_json" "$NAME")"
    id="$(printf '%s' "$existing" | cut -f1)"
    old_sha="$(printf '%s' "$existing" | cut -f2)"

    if [ -n "$id" ]; then
        echo "=== $NAME — EXISTS (id ${id}, current sha256:${old_sha}) → will UPDATE ==="
    else
        echo "=== $NAME — not in Bitwarden → will CREATE ==="
        if [ -z "$PROJECT_ID" ]; then
            PROJECT_ID="$(printf '%s' "$list_json" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: d=[]
for s in d if isinstance(d,list) else []:
    p=s.get("projectId")
    if p: print(p); break
')"
        fi
        if [ -z "$PROJECT_ID" ]; then
            echo "FATAL: could not derive a project id and --project-id was not given." >&2
            echo "       Refusing to guess. Run: bws project list" >&2
            return 1
        fi
        echo "    project: $PROJECT_ID"
    fi

    # A controlling terminal is required — the whole point is that the value is
    # typed, never pasted into a command line. Check FIRST and say so plainly.
    # Without this the script died on `v1: unbound variable` after two
    # "/dev/tty: Device not configured" lines: it failed closed, correctly, but
    # said nothing about why or what to do instead. An error path that cannot
    # explain itself is the same defect this repo's
    # checks-must-distinguish-unknown rule exists to stop.
    # The probe runs in a SUBSHELL: a failing redirection is reported by the
    # shell itself before the command executes, so a bare `: >/dev/tty
    # 2>/dev/null` still leaks "Device not configured" to stderr. Redirecting
    # the subshell captures it.
    if [ ! -r /dev/tty ] || ! ( : >/dev/tty ) 2>/dev/null; then
        echo "REFUSED: no controlling terminal, so the value cannot be typed." >&2
        echo "         This script deliberately has no --value flag: a value on the" >&2
        echo "         command line is exactly the exposure it exists to remove." >&2
        echo "" >&2
        echo "         Run it from your own shell:" >&2
        echo "             ~/.claude/scripts/bws_set_secret.sh $NAME" >&2
        echo "" >&2
        echo "         Nothing was written. $NAME is unchanged." >&2
        log "$NAME refused=no-tty"
        return 1
    fi

    # Hidden entry, twice.
    local v1="" v2=""
    printf 'Enter value for %s (input hidden): ' "$NAME" >&2
    IFS= read -rs v1 </dev/tty || true; printf '\n' >&2
    printf 'Re-enter to confirm: ' >&2
    IFS= read -rs v2 </dev/tty || true; printf '\n' >&2

    if [ "$v1" != "$v2" ]; then
        echo "REFUSED: the two entries do not match. Nothing was written." >&2
        log "$NAME refused=mismatch"
        return 1
    fi
    if [ -z "$v1" ]; then
        echo "REFUSED: empty value." >&2
        log "$NAME refused=empty"
        return 1
    fi
    if _looks_like_placeholder "$v1"; then
        echo "REFUSED: that looks like a placeholder, not a secret (length ${#v1})." >&2
        echo "         If it is genuinely the value, it is too short or too template-shaped" >&2
        echo "         for this script to accept. Use bws directly and accept the argv risk." >&2
        log "$NAME refused=placeholder len=${#v1}"
        return 1
    fi

    # ── Ground-truth verification (llm#1026) ────────────────────────────────
    # Typing the same typo twice is self-consistent, so double entry proves
    # nothing about correctness. Where the consuming system can be asked what
    # the value should be, ask it.
    local gt_cmd=""
    if [ "$NO_VERIFY" -eq 0 ]; then
        if [ -n "$VERIFY_CMD" ]; then
            gt_cmd="$VERIFY_CMD"
        elif command -v secret_ground_truth_cmd >/dev/null 2>&1; then
            gt_cmd="$(secret_ground_truth_cmd "$NAME")"
        fi
    fi

    if [ -n "$gt_cmd" ]; then
        local expected gt_rc
        expected="$(eval "$gt_cmd" 2>/dev/null)"; gt_rc=$?
        if [ "$gt_rc" -ne 0 ] || [ -z "$expected" ]; then
            # UNVERIFIABLE is not VERIFIED and is not MISMATCH. Say which.
            echo "NOTE: could not determine a ground-truth value for $NAME" >&2
            echo "      (verifier exited $gt_rc). Proceeding WITHOUT verification." >&2
            log "$NAME verify=unavailable rc=$gt_rc"
        elif [ "$(_digest "$expected")" != "$(_digest "$v1")" ]; then
            echo "REFUSED: the value does not match this machine's authoritative source." >&2
            echo "" >&2
            echo "           expected sha256: $(_digest "$expected")  (length ${#expected})" >&2
            echo "           you entered      $(_digest "$v1")  (length ${#v1})" >&2
            echo "" >&2
            echo "         Digests only — neither value is printed." >&2
            echo "         Equal lengths with different digests means a typo, not a" >&2
            echo "         format difference. A wrong-but-valid value would be accepted" >&2
            echo "         by every system downstream and fail silently at match time." >&2
            echo "" >&2
            echo "         Source consulted:" >&2
            printf '             %s\n' "$gt_cmd" >&2
            echo "" >&2
            echo "         If the authoritative source is the thing that is wrong," >&2
            echo "         re-run with --no-verify. Nothing was written." >&2
            log "$NAME refused=ground-truth-mismatch"
            return 1
        else
            echo "VERIFIED: matches this machine's authoritative source for $NAME."
            log "$NAME verify=matched"
        fi
    fi

    local new_sha; new_sha="$(_digest "$v1")"
    if [ -n "$old_sha" ] && [ "$new_sha" = "$old_sha" ]; then
        echo "REFUSED: new value is identical to the stored one — nothing to do." >&2
        echo "         (A re-run that changes nothing must not report success.)" >&2
        log "$NAME refused=noop sha=$new_sha"
        return 1
    fi

    local tok; tok="$(_keychain_token)"
    local out
    if [ -n "$id" ]; then
        out="$(BWS_ACCESS_TOKEN="$tok" "$BWS_BIN" secret edit --value "$v1" "$id" 2>&1)"; rc=$?
    else
        out="$(BWS_ACCESS_TOKEN="$tok" "$BWS_BIN" secret create "$NAME" "$v1" "$PROJECT_ID" 2>&1)"; rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        echo "FATAL: bws write failed (rc=$rc): $(printf '%s' "$out" | head -c 200)" >&2
        log "$NAME write-failed rc=$rc"
        return 1
    fi

    echo "OK: $NAME written (sha256:${new_sha}, length ${#v1})"
    log "$NAME written sha=$new_sha len=${#v1} mode=$([ -n "$id" ] && echo edit || echo create)"

    if [ "$DO_REGEN" -eq 1 ]; then
        if [ -x "$REGEN" ]; then
            echo "--- regenerating ~/.config/secrets.env from Bitwarden ---"
            # secrets_cache_regen.sh reads BWS_ACCESS_TOKEN from the environment
            # and does NOT consult the Keychain, which is why calling it bare
            # fails with "bws secret list -o env failed". Supply it here.
            BWS_ACCESS_TOKEN="$tok" "$REGEN" --apply || {
                echo "WARN: cache regen failed — BWS is updated, the local cache is not." >&2
                return 1
            }
        else
            echo "WARN: regen script not executable at $REGEN — BWS updated, cache NOT refreshed." >&2
        fi
    fi
    return 0
}

# ── Self-test ────────────────────────────────────────────────────────────────
# Exercises the pure functions only. Never calls bws, never touches the Keychain.

selftest() {
    local pass=0 fail=0
    ok(){ pass=$((pass+1)); echo "  PASS: $1"; }
    bad(){ fail=$((fail+1)); echo "  FAIL: $1"; }
    echo "bws_set_secret.sh --selftest"

    # The incident value must be refused.
    _looks_like_placeholder '<cachix-token>' && ok "'<cachix-token>' refused (the 2026-08-25 incident value)" \
                                             || bad "'<cachix-token>' accepted"
    for p in '<TOKEN>' 'YOUR_TOKEN_HERE' 'changeme' 'xxx' 'TODO' 'abc'; do
        _looks_like_placeholder "$p" && ok "'$p' refused" || bad "'$p' accepted"
    done

    # A realistic token must be accepted.
    local real='0.9adf53b1-532d-4b63-b4ce-b11b00c9813d.AbCdEfGhIjKlMnOpQrSt:UvWxYz0123456789'
    _looks_like_placeholder "$real" && bad "realistic token wrongly refused" \
                                    || ok "realistic token accepted"

    # Digest is stable, 12 chars, and does not contain the input.
    local d; d="$(_digest 'hunter2')"
    [ "${#d}" -eq 12 ] && ok "digest is 12 chars" || bad "digest length ${#d}"
    case "$d" in (*hunter2*) bad "digest leaks the value" ;; (*) ok "digest does not leak the value" ;; esac

    # _find_secret parses a list and reports nothing for an absent key.
    local j='[{"id":"i1","key":"A","value":"v1","projectId":"p1"}]'
    [ -n "$(_find_secret "$j" A)" ] && ok "_find_secret finds a present key" || bad "_find_secret missed a present key"
    [ -z "$(_find_secret "$j" ZZZ)" ] && ok "_find_secret returns nothing for an absent key" || bad "_find_secret invented a result"

    echo "  $pass passed, $fail failed"
    [ "$fail" -eq 0 ]
}

# ── Args ─────────────────────────────────────────────────────────────────────

[ $# -gt 0 ] || usage
while [ $# -gt 0 ]; do
    case "$1" in
        (--selftest)   selftest; exit $? ;;
        (--project-id) PROJECT_ID="${2:-}"; shift 2 ;;
        (--no-regen)   DO_REGEN=0; shift ;;
        (--verify-against) VERIFY_CMD="${2:-}"; shift 2 ;;
        (--no-verify)  NO_VERIFY=1; shift ;;
        (-h|--help)    usage ;;
        (-*)           echo "unknown flag: $1" >&2; usage ;;
        (*)            NAME="$1"; shift ;;
    esac
done
[ -n "$NAME" ] || usage

run_set
exit $?
