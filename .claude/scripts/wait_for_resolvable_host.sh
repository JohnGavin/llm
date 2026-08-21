#!/usr/bin/env bash
# wait_for_resolvable_host.sh — bounded wait for DNS to come up, shared by
# launchd cron wrappers that enter a nix shell and/or send SMTP mail
# (llm#947, llm#970).
#
# Problem this fixes:
#   Scheduled jobs fire at ~08:00-09:00, before this machine's network is
#   reliably up. A job that enters a nix shell without a warm GC-root dies
#   during evaluation ("Could not resolve host: github.com"); a job with a
#   warm GC-root still dies later trying to reach flakehub.com (the nix
#   registry) or smtp.gmail.com (mail send). No scheduled job previously
#   waited for DNS at all — see llm#970 for the "8 partial / 0 ok" signal
#   this produced in launchd_health_events.
#
# What this helper is NOT:
#   It does not fix nix evaluation or SMTP itself, and it does not write to
#   housekeeping_runs — callers own that write, exactly as they already own
#   the housekeeping_runs INSERT/UPDATE around every other step (see
#   cron_deploy_pull.sh for the same division of labour: this helper reports
#   a fact via return code + one log line; the caller decides what to do
#   with it).
#
# The core design decision: a job that cannot resolve DNS within the bound
# has NOT failed — its precondition (network) was absent. Callers MUST NOT
# record this as status='failed' in housekeeping_runs (llm#962 established
# that rendering an absent/unknown state as a failure trains readers to
# ignore the health surface). Use status='deferred' instead, and exit 0 so
# launchd does not record a "recent fail" for a job that correctly declined
# to run before its precondition existed.
#
# Usage (source, then call — mirrors cron_deploy_pull.sh):
#   # shellcheck disable=SC1091
#   source "${REPO_ROOT}/.claude/scripts/wait_for_resolvable_host.sh"
#   if ! wait_for_resolvable_host "" log; then
#     # DNS did not come up within the bound — defer, do not fail.
#     ... write housekeeping_runs status='deferred' if this script writes it ...
#     exit 0
#   fi
#
# Arguments to wait_for_resolvable_host():
#   $1  Comma-separated host list to try (optional). Falls back to
#       $WAIT_FOR_HOST_HOSTS, then to the built-in default
#       "github.com,smtp.gmail.com,flakehub.com" — hosts chosen because they
#       cover the two network dependencies actually seen failing in llm#970
#       (nix registry, SMTP) plus the general nixpkgs source.
#   $2  Name of an already-defined shell function to use for logging (e.g.
#       `log`). Invoked as `"$2" "message"`. Optional — falls back to
#       stderr when omitted or not a defined function.
#
# Env overrides:
#   WAIT_FOR_HOST_HOSTS      Default host list (see $1 above).
#   WAIT_FOR_HOST_TIMEOUT    Overall bound in seconds. Default 120.
#   WAIT_FOR_HOST_INTERVAL   Seconds between poll attempts. Default 5.
#
# Return code:
#   0  A host resolved within the bound — proceed. Logs
#      "network: resolved <host> after <N>s — proceeding".
#   2  No host resolved within the bound — defer. Logs
#      "network: DNS not up after <N>s — tried [<hosts>], none resolved — deferring".
#      2 (not 1) is used deliberately so callers can distinguish "gave up
#      waiting" from a generic script error.
#
# Never sleeps past the bound: each poll iteration bounds its own DNS
# lookups (see _wfrh_bounded) so a hung resolver tool cannot itself blow
# the timeout budget the way the npx incident did (see
# cc-startup-hang-npx-timeout memory / llm#716) — same _bounded pattern as
# .claude/scripts/burn_rate_check.sh.
#
# Standalone CLI (manual testing / selftest support):
#   bash wait_for_resolvable_host.sh [--hosts h1,h2] [--timeout N] [--interval N]
#   Exits with the same 0 / 2 codes as the function.
#
# Callers (llm#947, llm#970):
#   bin/launchd_health_weekly_cron.sh, bin/overnight_self_review_email_cron.sh,
#   bin/roborev_daily_cron.sh, bin/roborev_weekly_rollup_cron.sh,
#   .claude/scripts/stage1_findings_daily_cron.sh,
#   .claude/scripts/capability_registry_regen_cron.sh, bin/config_digest_cron.sh,
#   bin/kb_digest_daily_cron.sh.
#
# Tests: tests/test_wait_for_resolvable_host.sh (unresolvable-host case uses
# an .invalid TLD — reserved by RFC 2606, guaranteed to never resolve, so the
# negative-path test does not depend on any real host being down).

# NOTE: deliberately no `set -euo pipefail` at file scope — this file is
# sourced into callers that have already set their own shell options
# (mirrors cron_deploy_pull.sh). The CLI entry point at the bottom sets its
# own options when the file is executed directly.

# _wfrh_bounded <secs> <cmd> [args...]
# Portable bounded execution — identical fallback chain to
# .claude/scripts/burn_rate_check.sh's _bounded(): GNU timeout / gtimeout,
# then perl's alarm(2) (always present on macOS), then unbounded as a last
# resort. Prevents a single slow/hung DNS tool (e.g. nslookup's ~5s per-query
# default on some systems) from eating the whole WAIT_FOR_HOST_TIMEOUT budget.
_wfrh_bounded() {
  local secs="$1"; shift
  local _timeout_cmd
  _timeout_cmd="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
  if [ -n "${_timeout_cmd}" ]; then
    "${_timeout_cmd}" "${secs}" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'my $t = shift; alarm $t; exec @ARGV or die "exec: $!"' "${secs}" "$@"
  else
    "$@"
  fi
}

# _wfrh_resolves <host> — returns 0 if <host> resolves via any available
# system resolver, 1 otherwise. Tries tools in order of preference; the
# first one found on PATH is used (no need to try all of them per host).
_wfrh_resolves() {
  local host="$1"

  if command -v dscacheutil >/dev/null 2>&1; then
    # macOS-native. IMPORTANT: dscacheutil always exits 0, even when the
    # host does not resolve — the query result must be checked for content,
    # not the exit code (verified empirically: `dscacheutil -q host -a name
    # doesnotexist.invalid` exits 0 with empty stdout).
    _wfrh_bounded 3 dscacheutil -q host -a name "${host}" 2>/dev/null | grep -q '^ip_address:'
    return $?
  fi

  if command -v getent >/dev/null 2>&1; then
    _wfrh_bounded 3 getent hosts "${host}" >/dev/null 2>&1
    return $?
  fi

  if command -v host >/dev/null 2>&1; then
    _wfrh_bounded 3 host "${host}" >/dev/null 2>&1
    return $?
  fi

  if command -v nslookup >/dev/null 2>&1; then
    _wfrh_bounded 3 nslookup "${host}" >/dev/null 2>&1
    return $?
  fi

  if command -v dig >/dev/null 2>&1; then
    _wfrh_bounded 3 dig +short "${host}" 2>/dev/null | grep -q '.'
    return $?
  fi

  # Last resort: bash's own /dev/tcp pseudo-device resolves the hostname as
  # part of opening the connection — works with zero external tools. Bounded
  # the same way; a connect to a resolvable-but-unreachable host on :443
  # will fail fast (connection refused/timeout), which is an acceptable
  # false negative here — the other resolver tools are tried first.
  _wfrh_bounded 3 bash -c "exec 9<>\"/dev/tcp/${host}/443\"" >/dev/null 2>&1
  return $?
}

# wait_for_resolvable_host [hosts_csv] [log_fn]
# See file header for full contract. Returns 0 (resolved) or 2 (deferred).
wait_for_resolvable_host() {
  local hosts_csv="${1:-}"
  local log_fn="${2:-}"
  hosts_csv="${hosts_csv:-${WAIT_FOR_HOST_HOSTS:-github.com,smtp.gmail.com,flakehub.com}}"
  local timeout="${WAIT_FOR_HOST_TIMEOUT:-120}"
  local interval="${WAIT_FOR_HOST_INTERVAL:-5}"

  _wfrh_log() {
    if [ -n "${log_fn}" ] && declare -F "${log_fn}" >/dev/null 2>&1; then
      "${log_fn}" "$1"
    else
      echo "$1" >&2
    fi
  }

  local start_ts elapsed resolved_host host
  local -a hosts
  IFS=',' read -ra hosts <<< "${hosts_csv}"
  start_ts=$(date +%s)

  while true; do
    resolved_host=""
    for host in "${hosts[@]}"; do
      [ -z "${host}" ] && continue
      if _wfrh_resolves "${host}"; then
        resolved_host="${host}"
        break
      fi
    done

    if [ -n "${resolved_host}" ]; then
      elapsed=$(( $(date +%s) - start_ts ))
      _wfrh_log "network: resolved ${resolved_host} after ${elapsed}s — proceeding"
      return 0
    fi

    elapsed=$(( $(date +%s) - start_ts ))
    if [ "${elapsed}" -ge "${timeout}" ]; then
      _wfrh_log "network: DNS not up after ${elapsed}s — tried [${hosts_csv}], none resolved — deferring"
      return 2
    fi

    sleep "${interval}"
  done
}

# ─── Standalone CLI entry point (only when executed directly, not sourced) ──
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -uo pipefail
  _cli_hosts=""
  _cli_timeout=""
  _cli_interval=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --hosts) _cli_hosts="$2"; shift 2 ;;
      --timeout) _cli_timeout="$2"; shift 2 ;;
      --interval) _cli_interval="$2"; shift 2 ;;
      *) echo "wait_for_resolvable_host.sh: unknown arg '$1'" >&2; exit 64 ;;
    esac
  done
  [ -n "${_cli_timeout}" ] && export WAIT_FOR_HOST_TIMEOUT="${_cli_timeout}"
  [ -n "${_cli_interval}" ] && export WAIT_FOR_HOST_INTERVAL="${_cli_interval}"
  wait_for_resolvable_host "${_cli_hosts}" ""
  exit $?
fi
