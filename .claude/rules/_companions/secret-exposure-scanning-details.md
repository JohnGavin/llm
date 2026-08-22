# Companion: Secret Exposure Scanning — Origin Incidents, Tuning History, Heartbeat/Persistence

Dated narrative and implementation detail split out of the always-loaded
[`secret-exposure-scanning`](../secret-exposure-scanning.md) rule to keep it
under the rules size limit. The normative content (the Four Detectors table,
allowlist-vs-denylist distinction, self-reference exemption, fixture-value
heuristic, the NAME-and-VALUE credential-assignment contract, the
`--fix` scope, the Correctness Requirement, and Verification) stays in the
rule — none of it depends on this file. This file is (1) the full three-
incident origin narrative, (2) the tuning-round history that explains how
the current thresholds were reached, and (3) the DuckDB
heartbeat/persistence implementation detail — kept for audit trail, not
required to obey the rule or to safely edit the scanner.

## Origin — the three incidents in full

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

## Tuning History — how the current heuristic was reached

Tuning note (2026-08, round 1): day-1 signal was 615 findings at ~5%
precision, dominated by vendored/minified JS (pdfmake.js × 3 copies across
`.quarto`, `_freeze`, `docs`), the scanner's own pattern definitions, and R
test fixtures using `=`-style keyword-argument assignment (`totalTokens =
tokens`) that trips the same `TOKEN=<literal>` shape as a real credential.
The prune list, self-reference exemption, and fixture-value heuristic in the
main rule address the first two; the third is addressed per-fixture via the
fixture-value heuristic, not by pruning `tests/`. Combining the 13
credential-shape patterns into a single `grep -e ... -e ...` pass (was one
full-tree walk per pattern) cut runtime from ~10s to ~6.6s on this repo
(~1455 files post-prune).

Tuning note (2026-08, round 2 — credential-assignment redesign): round 1
left the detector-2 "any substring name match, any non-`$` value" heuristic
in place, which the round-1 note above already flagged as the dominant
remaining false-positive source (~27% of findings — `compat_mode`,
`date_key`, `KEYWORDS`, and any `.py`/`.R` assignment with a KEY/TOKEN/PAT-
shaped name, literal or not). That heuristic is replaced by the
name-AND-value check in the rule's "credential-assignment: NAME and VALUE"
section. Measured against the main `llm` checkout (pinned via
`REPO_ROOT=/path/to/checkout secret_exposure_scan.sh --scan`, since
`REPO_ROOT` otherwise auto-detects from the scanner's own location — see
the script's `REPO_ROOT` comment): `credential-assignment` findings dropped
from 295 to 28 (plus 2 `commented-credential-assignment`); total findings
dropped from 421 (measured pre-fix, this worktree) to 67; `bad-permissions`
(downstream of detector 2) dropped from 118 to 5. Runtime went from ~7.5s
to ~10.1s (`cred-shape` and detector 1/3 unchanged; the added per-candidate
name-segment + value-entropy computation costs more than it saves even
after collapsing each helper to a single `awk` call — see the
`name_segment_matches`/`looks_like_credential_value` comments in the
script for the subprocess-count accounting; still short of the ~3s target
from the round-1 tuning note, now further out of reach — correctness cost
more than the original headroom). All previously-known real findings were
re-verified present after the redesign:
`secrets.env` + both `.bak-*` copies, the three `~/.claude/env/*.env`
files, and `~/.zshenv` (via `cred-shape`). Two files in the original "must
survive" list, `~/.zshrc` and `~/.config/qBittorrent/qBittorrent.ini`, no
longer produce a finding — direct inspection (length/entropy computed
without printing the value, consistent with the no-leak contract) shows
neither currently holds a live secret: `qBittorrent.ini`'s `Password`
fields are empty, and `~/.zshrc`'s only prior candidate was a 9-character,
all-lowercase, low-entropy (2.64 bits/char) placeholder on an
already-commented line — this predates the credential-assignment redesign
entirely, since an empty value never matched `ASSIGN_RE` under the old
heuristic either.

Known residual noise NOT addressed by this pass (flagged for a follow-up
decision, not fixed here): `roborev_commit_msg_validator.sh`,
`secrets_to_bws.sh`, and `verify_no_launchd_secret_leak.sh` all need the
self-reference marker added — each defines the same credential-shaped
NAME literals this scanner looks for (a list of secret variable names to
check/migrate), which is exactly the "security tooling embeds the pattern
it detects" case the self-reference exemption exists for, but adding the
marker to those three files is out of this dispatch's write-scope
(`.claude/scripts/secret_exposure_scan.sh` and the rule doc only).

## Heartbeat and Persistence (llm#951)

The flat log the rule describes under "Log and Schedule" only records
`--fix` actions — a `--scan` run that finds nothing (or that stops firing
entirely) leaves no trace there, which is exactly the
`zero-metric-evidence-or-defect` failure mode: "0 findings" becomes
indistinguishable from "the scanner didn't run." Every `--scan`/`--fix`
invocation therefore also writes to `~/.claude/logs/unified.duckdb`
(override via `UNIFIED_DB_PATH`), following `housekeeping-framework`:

- **`housekeeping_runs`** — one heartbeat row per invocation (`task =
  'secret_exposure_scan'`), inserted at start and updated at the end with
  `ended_at`, `rows_written`, and `status` (`ok` on a completed scan —
  including a clean 0-finding one — or `failed` when the scan's findings
  tempfile could not even be created, e.g. `/tmp` unwritable or full).
- **`secret_scan_findings`** — one row per finding, batched (a single
  `INSERT ... SELECT` sourced from `read_csv()` per run, never one `INSERT`
  per finding), joined to `housekeeping_runs.id` via `run_id`. Carries
  exactly the same 6-tuple (detector, severity, file, line, name, note)
  `print_report()` already renders — the Correctness Requirement in the
  main rule applies unchanged: `note` is the fixed, generic, non-credential
  description; no column ever holds a matched value. Deterministic
  `md5(run_id:detector:file_path:line_num:name)` primary key makes
  replaying the write step for the same run idempotent.

Both writes are guarded exactly like the rest of this scanner: `duckdb`
absent, the DB missing, or any write failure is swallowed (`|| true`) and
never aborts the scan itself. See `write_findings_to_db`/`hk_run_start`/
`hk_run_end` in the script for the implementation, and `--selftest` for the
coverage (heartbeat on a zero-finding run, `status='failed'` on a forced
tempfile-creation failure, per-finding persistence + idempotent replay, the
sentinel absent from the DB, and the scan completing with `duckdb` entirely
off `PATH`).

The nightly digest email (`send_overnight_self_review_email.R`, "Secret-
exposure scan" section) reads this data: findings by detector for the
latest run, the delta vs the previous run (a rise in detector 2 means a new
plaintext credential appeared on disk since yesterday — the actionable
signal), and a loud line when the scanner has not fired in over 48h.
