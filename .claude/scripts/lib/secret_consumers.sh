#!/usr/bin/env bash
# secret_consumers.sh — shared consumer map + restart/verify machinery for
# rotate_secret.sh and rotate_gmail_password.sh (llm#958).
#
# IMPORT-SAFE: sourcing this file has NO side effects. It only defines
# variables and functions — no arg parsing, no selftest, no main flow runs.
# There is nothing here that needs a `[ "${BASH_SOURCE[0]}" = "$0" ]` guard
# because there is no executable section; if one is ever added, guard it.
#
# WHY THIS FILE EXISTS
# ---------------------
# rotate_secret.sh and rotate_gmail_password.sh each carried their own copy
# of CONSUMERS_GMAIL_APP_PASSWORD (byte-identical) plus copies of
# kind_get_pid(), kind_restart(), pid_start_time(), and
# restart_and_verify_consumer(). That is the same failure shape one layer up
# from the incident these scripts exist to prevent: on 2026-08-11..14
# GMAIL_APP_PASSWORD lived in six places with three different values, and
# the fix was one source of truth with everything else generated from it. A
# hand-maintained duplicate of the *consumer* map can drift the same way —
# add a sixth email job to one file and not the other, and a rotation
# reports success while a consumer keeps the old secret (llm#958).
#
# Both rotation scripts source this file, resolving the path relative to
# their own location (not the caller's cwd, since they run from arbitrary
# directories via launchd/cron/interactively):
#   LIB="$(dirname "${BASH_SOURCE[0]:-$0}")/lib/secret_consumers.sh"
#   source "$LIB"

# ── consumer map: secret name -> space-separated "kind:label" tokens ────────
# A secret NOT listed here is a WARNING at rotation time, not a silent pass:
# it means nobody has audited what holds it in memory yet. Add an entry the
# first time you find (or add) a consumer for a secret. `daemon:` consumers
# are self-daemonized processes with no launchd job; `launchd:` consumers are
# restarted via `launchctl kickstart -k`.
#
# CONSUMERS_GEMINI_API_KEY keeps `daemon:roborev` — the non-launchd consumer
# whose omission caused llm#936 (a launchd-only restart reported success
# while the self-daemonized `roborev daemon run` process kept the stale key
# for hours).
CONSUMERS_GEMINI_API_KEY="launchd:com.roborev.auto-refine daemon:roborev"
CONSUMERS_GMAIL_APP_PASSWORD="launchd:com.claude.overnight-self-review-email launchd:com.claude.kb-digest-email launchd:com.claude.config-digest-email launchd:com.claude.roborev-daily-email launchd:com.claude.roborev-weekly-rollup-email"

# ── consumer restart mechanisms — table-driven: a new kind is one `case` arm
#    in each of the two functions below, not a new code path. ──────────────
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

# ── restart + VERIFY a single consumer ───────────────────────────────────────
# Never treats "restart command exited 0" as proof. Captures PID + process
# start-time before and after; only reports success when both changed. A
# KeepAlive launchd job can return success from `kickstart -k` without ever
# actually cycling — that is how the 2026-08-13 GEMINI_API_KEY rotation
# reported "restarted" and exited 0 while the daemon consumer kept the stale
# key for hours (llm#936).
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
