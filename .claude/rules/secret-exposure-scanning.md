---
description: Aggressive, auto-triggered secret-exposure scanning via secret_exposure_scan.sh — never a rule/memory-only guard
scoping-justification: enforced by secret_exposure_scan.sh (a deterministic script, not advisory LLM recall), so it does not need the mandatory/safety-critical "never scoped" contract — see llm#943 item 3
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

Three incidents in one week — whole-environment/whole-file captures routed somewhere they should not go, plus plaintext credentials at rest with wrong permissions — led to an explicit user instruction that a rule alone is pointless because it can be ignored under pressure; the fix has to be **deterministic code that runs on a schedule and at session start, and that takes action** — not prose. Full incident narrative: companion doc.

## CRITICAL: This Is Enforced by `secret_exposure_scan.sh`, Not by Reading This File

The scanner (`.claude/scripts/secret_exposure_scan.sh`) is the enforcement mechanism. This rule documents its contract so an agent editing the scanner, a hook, or an environment-capturing script understands the four detectors and does not accidentally defeat them.

## The Four Detectors

| # | What it catches | Scope | Auto-fixed by `--fix`? |
|---|---|---|---|
| 1 | Whole-environment capture (`export -p`, `declare -x`, `set -o posix`, bare `printenv`/`env`) routed to a file or pipe, in `*.sh`/`*.R`/`*.py`/`*.plist` source | repo working tree | No — report only |
| 2 | Plaintext credential at rest: a literal credential-shaped value (`ghp_`, `sk-ant-`, `AKIA`, PEM key, etc.) OR a **credential-assignment** — see below for the name-AND-value heuristic | dotfiles/config + repo | No — report only, with the exact removal command |
| 3 | Bad permissions (not `600`/`400`) on a file Detector 2 flagged | any Detector-2-flagged file | **Yes** — `chmod 600` |
| 4 | A Detector-2-shaped assignment sitting on a **comment** line | dotfiles/config + repo | No — report only |

Detectors 2 and 4 both skip a file/value that matches the self-reference exemption or the fixture-value heuristic below.

## The Allowlist-vs-Denylist Rule (Detector 1's core distinction)

An environment capture filtered through a **denylist** (`grep -v`) is a **finding** — it fails open, knowing only what to hide, not what is safe to keep (exactly what incident 2 did). A capture filtered through an explicit **allowlist** (naming only the variables safe to expose) is not a finding. An unfiltered capture is worse than either and always a finding. Worked example: companion doc.

## Self-Reference Exemption (Detectors 2 + 4 only)

Security tooling must legitimately embed the same credential-shaped regex/name literals it exists to detect, otherwise self-flags on every run. A file opts out by declaring this exact marker anywhere in its **first 40 lines**: `# secret-exposure-scan: pattern-definitions`. Detectors 2 and 4 then skip literal-value matching for that file only; Detectors 1 (source-capture) and 3 (permissions) are unaffected — a security script is not exempt from being caught doing an unfiltered environment dump. Rationale for opt-in-marker over filename list, and the backlog of scripts still needing the marker: companion doc.

## Fixture-Value Heuristic (Detectors 2 + 4 only)

A matched literal is treated as an obviously-fake test/doc fixture — and skipped — when its line contains (case-insensitive) `EXAMPLE`, `FAKE`, `DUMMY`, `TEST`, `xxxx`, `AAAA`, `0000`, or a run of 8+ identical characters. This is a **value** heuristic, not a path heuristic: `tests/` is deliberately never pruned by directory, because a real credential accidentally committed to a test file must still be caught. A test file whose fixture values carry no such marker is still flagged — a prompt to add a marker to the fixture (e.g. rename `ghp_abc123...` to `ghp_FAKE_abc123...`), not a reason to widen the rule. Worked fixture-vs-real-value example: companion doc.

## credential-assignment: NAME and VALUE (Detectors 2 + 4)

The original credential-assignment heuristic fired on **NAME alone**, which produced ~89% of all detector-2 findings as false positives on this repo (295 of 331 at 2026-08 tuning — full tuning history in companion doc). The heuristic now requires **BOTH**:

| Check | Requirement |
|---|---|
| `name_segment_matches` | Name, split on `_`/`-`/`.`/camelCase, has a whole SEGMENT (not substring) equal to `key`, `token`, `secret`, `password`, `passwd`, `pat`, `credential`, or `apikey`. `compat_mode` → no match; `date_key` → matches (name alone still insufficient) |
| `looks_like_credential_value` | ≥16 chars after literal extraction (companion: "Value extraction"); contains a letter; not `$VAR`/path/URL/template/code-expression; Shannon entropy ≥ `CRED_ENTROPY_THRESHOLD` (**3.0** bits/char) — no digit requirement, see companion for why |

Worked examples (compat_mode, date_key, API_KEY_HEADER as non-findings; API_KEY and GMAIL_APP_PASSWORD as findings): companion doc.

## What `--fix` Will and Will Not Do

**Will** (safe, reversible): `chmod 600` a Detector-3-flagged file. **Will not**: delete or rewrite any file automatically — a human must confirm a value is genuinely dead before removal; `--fix` prints the manual removal command instead. Detector-1 findings are never auto-rewritten — allowlist-vs-denylist is a judgement call, not something to guess.

## Pruned Paths (Performance + Noise)

`PRUNE_ARGS` excludes directories that only mirror a source file already scanned, or are third-party/vendored: `.git`, `node_modules`, `_targets`, `worktrees`, `renv`, `library`, `.quarto`, `_freeze`, `docs`, `libs`, `site_libs`, plus `*.min.js`/`*.map`. Pruning removes noise without removing coverage. Tuning-round precision/runtime data: companion doc.

## Correctness Requirement (Non-Negotiable)

The scanner must never print a credential value — not in `--scan` output, `--fix` output, `--json`, or the log file. Findings carry file, line number, variable NAME, and detector id only. Verified by `--selftest`'s sentinel-value check (a fixture value that must not appear in stdout, stderr, or the log after a full scan+fix run).

## Log and Schedule

Every `--fix` action appends one line to `~/.claude/logs/secret_exposure_scan.log` (timestamp, detector id, path, action). Scheduled nightly 03:40 via `.claude/launchd/com.claude.secret-exposure-scan.plist`, currently `--scan --quiet` (report-only) for a soak week before `--fix --quiet` (promotion criterion in the plist comment). `--fast` scans the dotfile/config set only (session-start); full scan (default) is for the scheduled job.

## Heartbeat and Persistence (llm#951)

Every `--scan`/`--fix` invocation writes to `~/.claude/logs/unified.duckdb` (override `UNIFIED_DB_PATH`) — a `housekeeping_runs` heartbeat row plus a `secret_scan_findings` row per finding — so a clean 0-finding scan is distinguishable from the scanner not having run (the `zero-metric-evidence-or-defect` failure mode). Both writes are fail-open. Full schema, digest-email integration, `--selftest` coverage: companion doc.

## Verification

```bash
.claude/scripts/secret_exposure_scan.sh --selftest   # N/N PASS
.claude/scripts/secret_exposure_scan.sh --scan        # dry-run report
.claude/scripts/secret_exposure_scan.sh --fix          # safe remediation + report
```

`REPO_ROOT` auto-detects from the scanner's location, so a worktree copy measures itself, not the main checkout — pin explicitly to measure a specific checkout (command: companion doc).

## Related

- `credential-management` rule — never embed credentials in R code; retrieve from environment
- `destructive-fs-guard` rule — hook-enforced guard for destructive filesystem ops (a different enforcement mechanism, same "advisory rules get ignored" motivation)
- `housekeeping-framework` rule — the launchd plist + log-table conventions this scan follows
