#!/usr/bin/env bash
# render_signal_launchd_plists.sh — render the version-controlled Signal
# launchd plist templates (.claude/launchd/com.johngavin.signal-*.plist.template)
# into installable plists, substituting the SIGNAL_ACCOUNT secret from
# ~/.config/secrets.env (llm#949 single source of truth). (llm#946)
#
# Why this exists: the live Signal plists embed the account's real phone
# number as a literal ProgramArguments string. The repo is public, so the
# plists themselves can never be committed as-is (llm#946) — but leaving
# them unversioned means a hand-edit (e.g. moving a log path off /tmp, or
# fixing a Homebrew Cellar path that stopped existing after an upgrade —
# llm#937/#989) is lost on the next machine rebuild and invisible to review.
# This script is the seam: the STRUCTURE lives in git as a `.template` file
# with a placeholder; the SECRET lives only in ~/.config/secrets.env and is
# substituted at render time, never written to the repo.
#
# Usage:
#   render_signal_launchd_plists.sh --dry-run [--name <label>]
#     Render each template into a throwaway temp file (deleted before this
#     invocation returns), diff it against the currently-installed
#     ~/Library/LaunchAgents/<label>.plist (if present), and print exactly
#     what --apply would do. Writes NOTHING persistent — this is the only
#     mode a worktree-sandboxed agent should ever invoke.
#
#   render_signal_launchd_plists.sh --check [--name <label>]
#     Same rendering, but quiet unless drift is found. Also flags a
#     versioned Homebrew Cellar path in ProgramArguments as its own defect
#     class (llm#937/#989), independent of template/secret drift. Intended
#     for a health-audit cron, not interactive use.
#       exit 0  no drift, no defects
#       exit 1  usage error / SIGNAL_ACCOUNT missing from secrets.env
#       exit 2  drift and/or a Cellar-path defect found
#
#   render_signal_launchd_plists.sh --apply [--name <label>] [--reload]
#     Render into the persistent, gitignored staging directory
#     .claude/state/signal-launchd/, cp the result into
#     ~/Library/LaunchAgents/<label>.plist, and (with --reload) unload+load
#     it via launchctl. ORCHESTRATOR ONLY — writes outside the repo
#     worktree; never run this mode from an agent sandbox.
#
# Overridable for tests (never touch the real machine when set):
#   LAUNCHD_TEMPLATE_DIR   default: <repo>/.claude/launchd
#   SECRETS_ENV_FILE       default: $HOME/.config/secrets.env
#   LAUNCH_AGENTS_DIR      default: $HOME/Library/LaunchAgents
#   STAGING_DIR            default: <repo>/.claude/state/signal-launchd
#   LAUNCHCTL_BIN          default: launchctl
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

LAUNCHD_TEMPLATE_DIR="${LAUNCHD_TEMPLATE_DIR:-$REPO_ROOT/.claude/launchd}"
SECRETS_ENV_FILE="${SECRETS_ENV_FILE:-$HOME/.config/secrets.env}"
LAUNCH_AGENTS_DIR="${LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
STAGING_DIR="${STAGING_DIR:-$REPO_ROOT/.claude/state/signal-launchd}"
LAUNCHCTL_BIN="${LAUNCHCTL_BIN:-launchctl}"

MODE=""
ONLY_NAME=""
RELOAD=0

usage() {
  echo "usage: $0 --dry-run|--check|--apply [--name <label>] [--reload]" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) MODE="dry-run" ;;
    --check) MODE="check" ;;
    --apply) MODE="apply" ;;
    --reload) RELOAD=1 ;;
    --name) ONLY_NAME="${2:-}"; shift ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
  shift
done

[ -n "$MODE" ] || usage

# Discover job labels from the template files present. A label is the
# template filename with the ".plist.template" suffix removed.
LABELS=()
for tmpl in "$LAUNCHD_TEMPLATE_DIR"/com.johngavin.signal-*.plist.template; do
  [ -e "$tmpl" ] || continue
  base="$(basename "$tmpl")"
  label="${base%.plist.template}"
  if [ -n "$ONLY_NAME" ] && [ "$label" != "$ONLY_NAME" ]; then
    continue
  fi
  LABELS+=("$label")
done

if [ "${#LABELS[@]}" -eq 0 ]; then
  echo "no matching template(s) found in $LAUNCHD_TEMPLATE_DIR" >&2
  exit 1
fi

# Defect class (llm#937/#989): a template that hardcodes a Homebrew Cellar
# version directory instead of the version-stable /opt/homebrew/bin symlink
# will break on the next `brew upgrade`, silently, the same way the daemon
# plist and signal_notes_sync.sh both did historically. Checked against every
# template unconditionally, independent of --dry-run/--check/--apply.
for tmpl in "$LAUNCHD_TEMPLATE_DIR"/com.johngavin.signal-*.plist.template; do
  [ -e "$tmpl" ] || continue
  if grep -q '/opt/homebrew/Cellar/signal-cli/' "$tmpl"; then
    echo "DEFECT: template $(basename "$tmpl") hardcodes a versioned Homebrew Cellar path — use /opt/homebrew/bin/signal-cli (the version-stable symlink) instead (llm#937/#989)" >&2
    exit 1
  fi
done

# _render_one <template-path> <secret-value-or-empty> <out-path>
# Bash string substitution (not sed) so the secret value is never
# interpreted as a regex/replacement pattern.
_render_one() {
  local tmpl="$1" secret="$2" out="$3"
  local content
  content="$(cat "$tmpl")"
  if [[ "$content" == *"__SIGNAL_ACCOUNT__"* ]]; then
    if [ -z "$secret" ]; then
      echo "SIGNAL_ACCOUNT is not set in $SECRETS_ENV_FILE — add it before rendering (see .claude/launchd/README.md, llm#946, llm#949)" >&2
      return 1
    fi
    content="${content//__SIGNAL_ACCOUNT__/$secret}"
  fi
  printf '%s\n' "$content" > "$out"
}

# Load SIGNAL_ACCOUNT the same way with-secrets does — sourced into this one
# process only, never exported into a long-lived environment.
SIGNAL_ACCOUNT_VALUE=""
if [ -r "$SECRETS_ENV_FILE" ]; then
  SIGNAL_ACCOUNT_VALUE="$(
    set -a
    # shellcheck disable=SC1090
    . "$SECRETS_ENV_FILE"
    set +a
    printf '%s' "${SIGNAL_ACCOUNT:-}"
  )"
fi

overall_rc=0

case "$MODE" in
  dry-run|check)
    for label in "${LABELS[@]}"; do
      tmpl="$LAUNCHD_TEMPLATE_DIR/${label}.plist.template"
      live="$LAUNCH_AGENTS_DIR/${label}.plist"
      tmp="$(mktemp "${TMPDIR:-/tmp}/render_signal_XXXXXX.plist")"

      if ! _render_one "$tmpl" "$SIGNAL_ACCOUNT_VALUE" "$tmp"; then
        rm -f "$tmp"
        overall_rc=1
        continue
      fi

      drift=0
      if [ ! -f "$live" ]; then
        drift=1
        if [ "$MODE" = "dry-run" ]; then
          echo "--- $label ---"
          echo "NOT INSTALLED: $live does not exist yet."
          echo "Would run: cp <rendered> '$live'"
        else
          echo "DRIFT: $label — not installed at $live"
        fi
      elif ! diff -q "$tmp" "$live" >/dev/null 2>&1; then
        drift=1
        if [ "$MODE" = "dry-run" ]; then
          echo "--- $label ---"
          echo "DRIFT: live plist differs from template+secret render"
          diff -u "$live" "$tmp" | sed "s#$tmp#<rendered $label>#" || true
        else
          echo "DRIFT: $label — live plist differs from template+secret render"
        fi
      else
        [ "$MODE" = "dry-run" ] && { echo "--- $label ---"; echo "OK: matches live plist"; }
      fi

      if [ -f "$live" ] && grep -q '/opt/homebrew/Cellar/signal-cli/' "$live"; then
        drift=1
        echo "DEFECT: $label — live plist hardcodes a versioned Homebrew Cellar path (llm#937/#989)"
      fi

      if [ "$MODE" = "dry-run" ]; then
        echo "Would run (if --apply --reload): $LAUNCHCTL_BIN unload '$live'; $LAUNCHCTL_BIN load '$live'"
      fi

      rm -f "$tmp"
      [ "$drift" -eq 1 ] && overall_rc=2
    done
    ;;

  apply)
    mkdir -p "$STAGING_DIR"
    for label in "${LABELS[@]}"; do
      tmpl="$LAUNCHD_TEMPLATE_DIR/${label}.plist.template"
      rendered="$STAGING_DIR/${label}.plist"
      if ! _render_one "$tmpl" "$SIGNAL_ACCOUNT_VALUE" "$rendered"; then
        overall_rc=1
        continue
      fi
      cp "$rendered" "$LAUNCH_AGENTS_DIR/${label}.plist"
      echo "installed: $LAUNCH_AGENTS_DIR/${label}.plist"
      if [ "$RELOAD" -eq 1 ]; then
        "$LAUNCHCTL_BIN" unload "$LAUNCH_AGENTS_DIR/${label}.plist" 2>/dev/null || true
        "$LAUNCHCTL_BIN" load "$LAUNCH_AGENTS_DIR/${label}.plist"
        echo "reloaded: $label"
      fi
    done
    ;;
esac

exit "$overall_rc"
