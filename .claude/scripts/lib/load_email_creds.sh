#!/usr/bin/env bash
# load_email_creds.sh -- single-source GMAIL_* credential loader for the cron
# email wrappers (bin/*_cron.sh). Source it; do not execute it.
#
# WHY THIS EXISTS (llm#949, .claude/rules/secrets-single-source.md)
# BWS is the system of record and ~/.config/secrets.env is its derived cache.
# The per-job files ~/.claude/env/{kb_digest,overnight_self_review,
# roborev_email}.env each carried their own copy of GMAIL_APP_PASSWORD, which
# credential_single_source_check.sh reports as a duplicate-name violation.
# Every wrapper now gets GMAIL_* from ONE place through this helper, so the
# per-job files can be deleted and a rotation has one target.
#
# SOURCES, IN PRIORITY ORDER
#   1. The process environment -- already populated when the job was launched
#      through `with-secrets` / `bws_launcher.sh` (the launchd wrappers do).
#   2. ${SECRETS_ENV_FILE:-~/.config/secrets.env} -- for manual runs and for
#      wrappers launched without with-secrets. Only the three keys named in
#      _EMAIL_CRED_KEYS are read (never the whole file), values already present
#      in the environment are never overridden, and nothing is echoed.
#
# FAIL CLOSED
#   load_email_credentials returns 1 when GMAIL_USERNAME or GMAIL_APP_PASSWORD
#   is still empty. It never treats "nothing found" as "rely on the existing
#   environment" (the silent fallback SECRETS_MIGRATION.md flagged).
#   email_credentials_gate wraps it: missing credentials abort the run (return
#   1) unless DRYRUN=1 / EMAIL_DRY_RUN=1, where the run may continue because no
#   mail is sent -- and says so loudly.
#
# NON-SECRET CONFIG
#   REPORT_RECIPIENT is an address already held in secrets.env with the rest of
#   the email identity, so it is loaded alongside the credentials.
#   ROBOREV_DASHBOARD_URL is an OPTIONAL override (see the roborev plists) and
#   is deliberately NOT sourced here: it is not a secret, so it belongs in the
#   job's plist EnvironmentVariables if wanted, not in a credential file.

_EMAIL_CRED_KEYS="GMAIL_USERNAME GMAIL_APP_PASSWORD REPORT_RECIPIENT"

# load_email_credentials [log_fn]
# Exports the keys found; returns 0 iff GMAIL_USERNAME and GMAIL_APP_PASSWORD
# are both non-empty afterwards.
load_email_credentials() {
  local logfn="${1:-echo}"
  local src="${SECRETS_ENV_FILE:-${HOME}/.config/secrets.env}"
  local line key val loaded=0

  if [ -n "${GMAIL_USERNAME:-}" ] && [ -n "${GMAIL_APP_PASSWORD:-}" ]; then
    "${logfn}" "Credentials present in environment (with-secrets / bws injection)"
  elif [ -r "${src}" ]; then
    while IFS= read -r line || [ -n "${line}" ]; do
      line="${line#"${line%%[![:space:]]*}"}"   # strip leading whitespace
      line="${line#export }"
      key="${line%%=*}"
      case " ${_EMAIL_CRED_KEYS} " in
        *" ${key} "*) ;;
        *) continue ;;
      esac
      val="${line#*=}"
      val="${val#\"}"; val="${val%\"}"
      val="${val#\'}"; val="${val%\'}"
      # Never override a value the caller already injected.
      [ -n "${!key:-}" ] && continue
      export "${key}=${val}"
      loaded=1
    done < "${src}"
    "${logfn}" "Credentials read from single source ${src} (keys loaded: ${loaded})"
  else
    "${logfn}" "ERROR: single-source credentials file ${src} is not readable and GMAIL_* is not in the environment"
  fi

  local missing=""
  [ -n "${GMAIL_USERNAME:-}" ] || missing="${missing} GMAIL_USERNAME"
  [ -n "${GMAIL_APP_PASSWORD:-}" ] || missing="${missing} GMAIL_APP_PASSWORD"
  if [ -n "${missing}" ]; then
    "${logfn}" "ERROR: missing after load:${missing} (rotate/fix in BWS, then secrets_cache_regen.sh --apply)"
    return 1
  fi
  return 0
}

# email_credentials_gate [log_fn]
# Return 0 = proceed, 1 = abort the run. Missing credentials abort unless this
# is a dry run (DRYRUN=1 or EMAIL_DRY_RUN=1), in which case the run proceeds
# with a loud WARN because no mail can be sent with them anyway.
email_credentials_gate() {
  local logfn="${1:-echo}"
  if load_email_credentials "${logfn}"; then
    return 0
  fi
  if [ "${DRYRUN:-0}" = "1" ] || [ "${EMAIL_DRY_RUN:-0}" = "1" ]; then
    "${logfn}" "WARN: no email credentials -- continuing ONLY because this is a dry run (nothing will be sent)"
    return 0
  fi
  "${logfn}" "ABORT: email credentials unavailable and this is not a dry run -- failing closed (no fallback to ambient environment)"
  return 1
}
