#!/bin/bash
# verify_no_launchd_secret_leak.sh <launchd-job-label>
#
# Post-apply check for the with-secrets migration (#791, #615). Confirms a
# launchd job's inherited environment does NOT contain any secret key that
# used to be pushed globally by com.johngavin.load-secrets via
# `launchctl setenv`. Run by the ORCHESTRATOR after live-applying the
# migration (see .claude/launchd/SECRETS_MIGRATION.md) — this script itself
# needs no secrets and must not be run by an agent inside a sandboxed
# worktree (it inspects the live launchd domain on this machine).
#
# Exit codes:
#   0  no leaked secret key found
#   1  usage error / launchctl unavailable
#   2  a secret key was found in the job's inherited environment or in the
#      gui-domain-wide environment (the launchctl setenv leak surface)
set -uo pipefail

label="${1:-}"
if [ -z "$label" ]; then
  echo "usage: $0 <launchd-job-label>" >&2
  exit 1
fi

if ! command -v launchctl >/dev/null 2>&1; then
  echo "launchctl not found — cannot verify" >&2
  exit 1
fi

uid="$(id -u)"

# Secret key name patterns that must never appear in an inherited/global
# launchd environment. Extend this list if new secret categories are added
# to ~/.config/secrets.env.
secret_patterns='OPENAI_API_KEY|GEMINI_API_KEY|GOOGLE_API_KEY|GITHUB_PAT|GH_TOKEN|HUGGING|ELEVENLABS|GUARDIAN_API|GMAIL_USERNAME|GMAIL_APP_PASSWORD|REPORT_RECIPIENT'

found=0

job_dump="$(launchctl print "gui/${uid}/${label}" 2>&1)"
if echo "$job_dump" | grep -qE "$secret_patterns"; then
  echo "LEAK: job '${label}' inherited environment contains a secret key:" >&2
  echo "$job_dump" | grep -E "$secret_patterns" >&2
  found=1
fi

# The actual leak surface is the gui-domain-wide environment set by
# `launchctl setenv` (com.johngavin.load-secrets, now retired) — check it too.
domain_dump="$(launchctl print "gui/${uid}" 2>&1)"
if echo "$domain_dump" | grep -qE "$secret_patterns"; then
  echo "LEAK: gui/${uid} domain-wide environment still contains a secret key:" >&2
  echo "$domain_dump" | grep -E "$secret_patterns" >&2
  found=1
fi

if [ "$found" -eq 0 ]; then
  echo "OK: no secret key found for job '${label}' or gui/${uid} domain"
  exit 0
fi

exit 2
