#!/usr/bin/env bash
# secret_ground_truth.sh — commands that print the AUTHORITATIVE value of a
# secret, read from the system that actually consumes it.
#
# WHY
# ---
# bws_set_secret.sh takes a value on hidden stdin, twice, and compares the two
# entries. That catches a slip. It does not catch a MISREADING: typing the same
# typo twice is perfectly self-consistent, and the script reports success.
#
# On 2026-08-25 SIGNAL_ACCOUNT was re-entered after being lost, one or two
# digits wrong. Everything downstream reported success — value written, cache
# regenerated, 16 keys. Nothing errored, because a wrong account is not an
# invalid account: signal-cli would simply never match `destinationNumber` and
# capture would stay silently dead. The failure was found only by comparing
# digests against signal-cli's own accounts.json.
#
# Some secrets have a discoverable ground truth on this machine. Where one
# exists, there is no reason to trust typing at all.
#
# CONTRACT
#   Define GROUND_TRUTH_<SECRET_NAME> as a shell command string that prints the
#   expected value to stdout and nothing else. Exit non-zero (or print nothing)
#   when the value cannot be determined — callers MUST treat that as
#   "cannot verify", never as "verified" or "mismatch"
#   (checks-must-distinguish-unknown, llm#1021).
#
#   Never write a verifier that prints the value anywhere a human or a log can
#   see it. Callers compare digests only.
#
# llm#1026

# ── SIGNAL_ACCOUNT ───────────────────────────────────────────────────────────
# signal-cli stores the linked account in its own accounts.json. That file is
# the account the daemon actually receives for, so it is the correct authority
# — not the secrets cache, which is a copy that had already been lost once.
GROUND_TRUTH_SIGNAL_ACCOUNT='python3 -c "
import json, sys
p = \"$HOME/.local/share/signal-cli/data/accounts.json\"
try:
    d = json.load(open(p))
except Exception:
    sys.exit(1)
accs = d.get(\"accounts\") or []
if len(accs) != 1:
    sys.exit(1)
n = accs[0].get(\"number\") or \"\"
if not n:
    sys.exit(1)
print(n)
"'

# Deliberately exactly one entry for now. A verifier that is wrong is worse
# than none: it would refuse a correct value with an authoritative-sounding
# message. Add one only when the source is genuinely the consuming system.
#
# Candidates considered and NOT added:
#   GH_TOKEN            — `gh auth token` prints the ACTIVE token, which may be
#                         the very stale one being replaced. Circular.
#   CACHIX_AUTH_TOKEN   — no local authority; the remote cannot be asked to
#                         echo a token back.
#   GMAIL_APP_PASSWORD  — no local authority.

# Print the ground-truth command for a secret name, or nothing.
secret_ground_truth_cmd() {
    local name="$1" var="GROUND_TRUTH_${1}"
    printf '%s' "${!var:-}"
}
