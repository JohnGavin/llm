---
description: Aggressive, auto-triggered secret-exposure scanning via secret_exposure_scan.sh — never a rule/memory-only guard
paths:
  - "**/*.sh"
  - ".claude/scripts/**"
  - ".claude/hooks/**"
  - "bin/**"
  - "**/.zshenv"
  - "**/.zshrc"
  - "**/secrets.env"
  - "**/*.plist"
---

# Rule: Secret Exposure Scanning (Enforced by Script, Not Advisory)

## Origin

Three incidents in one week, all the same shape — a whole-environment or
whole-file capture routed somewhere it should not go, plus plaintext
credentials at rest with wrong permissions:

1. `gh issue comment --body "...printenv..."` spliced the whole shell
   environment into a **public GitHub comment**. 14 live credentials; 4
   auto-revoked by scanners.
2. `default.sh` ran `export -p | grep -v <denylist> > nix_env.sh`, writing
   the whole environment to a **world-readable file** (mode 644) on every
   dev-shell entry. 11 live credentials.
3. A migration script "commented out" secrets instead of deleting them —
   three plaintext credentials sat fully readable in `~/.zshenv`.

Explicit user instruction: a rule alone is pointless because it can be
ignored under pressure. The fix has to be **deterministic code that runs
on a schedule and at session start, and that takes action** — not prose.

## CRITICAL: This Is Enforced by `secret_exposure_scan.sh`, Not by Reading This File

The scanner (`.claude/scripts/secret_exposure_scan.sh`) is the enforcement
mechanism. This rule documents its contract so a human or an agent editing
the scanner, a hook, or a script that captures environment state
understands the four detectors and does not accidentally defeat them.

## The Four Detectors

| # | What it catches | Scope | Auto-fixed by `--fix`? |
|---|---|---|---|
| 1 | Whole-environment capture (`export -p`, `declare -x`, `set -o posix`, bare `printenv`/`env`) routed to a file or pipe, in `*.sh`/`*.R`/`*.py`/`*.plist` source | repo working tree | No — report only |
| 2 | Plaintext credential at rest: a literal credential-shaped value (`ghp_`, `sk-ant-`, `AKIA`, PEM key, etc.) OR a `KEY\|TOKEN\|SECRET\|PASSWORD\|PASSWD\|PAT\|CREDENTIAL`-named variable assigned a literal (non-`$`) value | dotfiles/config + repo | No — report only, with the exact removal command |
| 3 | Bad permissions (not `600`/`400`) on a file Detector 2 flagged | any Detector-2-flagged file | **Yes** — `chmod 600` |
| 4 | A Detector-2-shaped assignment sitting on a **comment** line | dotfiles/config + repo | No — report only |

## The Allowlist-vs-Denylist Rule (Detector 1's core distinction)

An environment capture filtered through a **denylist** (`grep -v`,
`grep --invert-match`) is a **finding**, because it fails open — it only
knows what to hide, not what is safe to keep. This is exactly what
incident 2 did. A capture filtered through an explicit **allowlist**
(`grep -E "^declare -x (PATH|NIX_STORE)="`, naming only the variables that
are safe to expose) is not a finding. An unfiltered capture (no grep at
all between the dump and the redirect/pipe) is worse than either and is
always a finding.

```bash
# FINDING — denylist fails open
export -p | grep -vE "PASSWORD|TOKEN" > nix_env.sh

# NOT a finding — allowlist names exactly what's safe
export -p | grep -E "^declare -x (PATH|NIX_STORE)=" > nix_env.sh
```

## What `--fix` Will and Will Not Do

**Will** (safe, reversible, no data change): `chmod 600` a Detector-3-flagged file.

**Will not**: delete or rewrite any file automatically. Deleting a
credential file or a secret line is not a safe automatic action — a
human must confirm the value is genuinely dead before it is removed.
`--fix` prints the exact manual removal command instead. Detector-1
findings are never auto-rewritten — allowlist-vs-denylist is a judgement
call about which variables are actually needed downstream, not something
a script should guess.

## Correctness Requirement (Non-Negotiable)

The scanner must never print a credential value — not in `--scan`
output, `--fix` output, `--json`, or the log file. Findings carry file,
line number, variable NAME, and a detector id only. Verified by
`--selftest`'s sentinel-value check (a fixture value that must not appear
in stdout, stderr, or the log after a full scan + fix run).

## Log and Schedule

- Every `--fix` action appends one line to
  `~/.claude/logs/secret_exposure_scan.log` (ISO-8601 UTC timestamp,
  detector id, path, action taken).
- Scheduled nightly at 03:40 via
  `.claude/launchd/com.claude.secret-exposure-scan.plist`, running
  `--fix --quiet` so the safe remediation happens unattended.
- `--fast` scans the dotfile/config set only (skips the repo walk) for a
  session-start path; the full scan (default) is for the scheduled job.

## Verification

```bash
.claude/scripts/secret_exposure_scan.sh --selftest   # N/N PASS
.claude/scripts/secret_exposure_scan.sh --scan        # dry-run report
.claude/scripts/secret_exposure_scan.sh --fix          # safe remediation + report
```

## Related

- `credential-management` rule — never embed credentials in R code; retrieve from environment
- `destructive-fs-guard` rule — hook-enforced guard for destructive filesystem ops (a different enforcement mechanism, same "advisory rules get ignored" motivation)
- `housekeeping-framework` rule — the launchd plist + log-table conventions this scan follows
