#!/usr/bin/env bash
# roborev_daemon_launcher.sh — launchd entrypoint for `roborev daemon run`.
#
# WHY THIS EXISTS (llm#936, llm#956)
# -----------------------------------------------------------------------------
# `roborev daemon start` self-daemonizes: it forks, detaches, and hands the
# caller back a shell prompt. Nothing then owns its lifecycle. That daemon ran
# for 7 days holding a stale GEMINI_API_KEY after a rotation — nothing
# restarted it, nothing bounded its age, and it appeared in no health check,
# so a week of 100% review failure was invisible (llm#936).
#
# The fix is not "restart it more often" — a periodic forced restart would
# have made the symptom vanish every morning and return every evening,
# without anyone ever learning why review agents kept failing. The fix is
# supervision: launchd owns the process (KeepAlive/RunAtLoad in
# com.roborev.daemon.plist), both stdout and stderr are captured, and this
# launcher re-reads secrets from disk on every single start launchd performs
# — every crash-restart and every reboot — instead of a long-lived parent
# shell capturing them once and outliving every subsequent rotation.
#
# This script does exactly two things: (1) assert required secrets are
# present, re-read fresh, every time it runs; (2) `exec` the real daemon in
# the FOREGROUND so its PID becomes launchd's supervised PID. It must NEVER
# call `roborev daemon start` — that forks a grandchild, launchd would see
# THIS process exit cleanly, and KeepAlive would spin up a new detached
# daemon on every restart while eventually giving up (or worse, accumulating
# orphans).
#
# Pattern followed verbatim from roborev_auto_refine.sh's secrets block —
# see that script's header comment for the fuller incident history
# (llm#791 / llm#936: launchd provides only the plist's EnvironmentVariables,
# never a login shell, so ~/.zshenv sourcing ~/.config/secrets.env never
# reaches a launchd-started process).
#
# Usage (launchd only — do not invoke `daemon` by hand, see the rule below):
#   roborev_daemon_launcher.sh
#
# Manual dry-run (proves the sourcing + exec plan without touching the real
# daemon — see .claude/rules/long-running-process-supervision.md):
#   ROBOREV=/path/to/stub SECRETS_ENV_FILE=/path/to/fake.env \
#     bash roborev_daemon_launcher.sh
#
# See also: .claude/launchd/com.roborev.daemon.plist (install/verify/rollback
# sequence), .claude/rules/long-running-process-supervision.md (the general
# invariant this implements).

set -euo pipefail

# ── Secrets (llm#791 / llm#936) ───────────────────────────────────────────────
# ~/.config/secrets.env is the single source of truth and ~/.zshenv already
# sources it — but ONLY for zsh. launchd does not run a shell at all, so a
# launchd-started daemon gets exactly what its plist's EnvironmentVariables
# block provides, which here is PATH and nothing else.
#
# Overridable for dry-run testing so verification never touches the real
# secrets cache (mirrors the ROBOREV_DB / CONFIG_TOML overridable-path
# pattern already used by roborev_agent_health.sh).
SECRETS_ENV_FILE="${SECRETS_ENV_FILE:-$HOME/.config/secrets.env}"
if [ -r "$SECRETS_ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$SECRETS_ENV_FILE"
  set +a
fi

# Fail loud rather than failing silently for however long the process happens
# to stay up. A daemon that cannot authenticate should not start.
_missing=""
for _v in GEMINI_API_KEY; do
  [ -n "${!_v:-}" ] || _missing="$_missing $_v"
done
if [ -n "$_missing" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') FATAL: missing secret(s):$_missing — expected in $SECRETS_ENV_FILE (llm#791, llm#936)" >&2
  exit 78   # EX_CONFIG
fi

# Mark session as scheduled/automated for llmtelemetry_emit.sh (#322 Phase 2).
# Propagates to any claude-code review agent the daemon spawns so the Stop
# hook emits "trigger":"scheduled" without requiring a /bye sentinel.
export CLAUDE_TRIGGER="${CLAUDE_TRIGGER:-scheduled}"

ROBOREV="${ROBOREV:-$(command -v roborev 2>/dev/null || echo /usr/local/bin/roborev)}"

# ── Start-record telemetry (llm#950) — fail-open, never blocks the daemon ────
# One line per launchd-triggered start (RunAtLoad, or KeepAlive after a
# crash) so "how many times has this restarted" is queryable instead of
# invisible, the same failure mode that hid the 7-day stale-key outage.
if [ -x "$HOME/.claude/scripts/hook_event_emit.sh" ]; then
  "$HOME/.claude/scripts/hook_event_emit.sh" \
    "roborev_daemon_launcher" "daemon_start" "pid=$$ roborev=$ROBOREV" \
    >/dev/null 2>&1 || true
fi

# Replace this process with the real daemon so its PID is the one launchd
# supervises — never fork it off as a child (that reintroduces the exact
# self-daemonizing problem this launcher exists to remove).
exec "$ROBOREV" daemon run
