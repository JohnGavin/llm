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

Three incidents in one week, all the same shape — a whole-environment or
whole-file capture routed somewhere it should not go, plus plaintext
credentials at rest with wrong permissions (a public-comment env splice, a
world-readable `nix_env.sh` dump, and secrets "commented out" instead of
deleted in `~/.zshenv`). Full incident-by-incident detail is in the
companion. Explicit user instruction: a rule alone is pointless because it
can be ignored under pressure. The fix has to be **deterministic code that
runs on a schedule and at session start, and that takes action** — not
prose.

## CRITICAL: This Is Enforced by `secret_exposure_scan.sh`, Not by Reading This File

The scanner (`.claude/scripts/secret_exposure_scan.sh`) is the enforcement
mechanism. This rule documents its contract so a human or an agent editing
the scanner, a hook, or a script that captures environment state
understands the four detectors and does not accidentally defeat them.

## The Four Detectors

| # | What it catches | Scope | Auto-fixed by `--fix`? |
|---|---|---|---|
| 1 | Whole-environment capture (`export -p`, `declare -x`, `set -o posix`, bare `printenv`/`env`) routed to a file or pipe, in `*.sh`/`*.R`/`*.py`/`*.plist` source | repo working tree | No — report only |
| 2 | Plaintext credential at rest: a literal credential-shaped value (`ghp_`, `sk-ant-`, `AKIA`, PEM key, etc.) OR a **credential-assignment** — see below for the name-AND-value heuristic | dotfiles/config + repo | No — report only, with the exact removal command |
| 3 | Bad permissions (not `600`/`400`) on a file Detector 2 flagged | any Detector-2-flagged file | **Yes** — `chmod 600` |
| 4 | A Detector-2-shaped assignment sitting on a **comment** line | dotfiles/config + repo | No — report only |

Detectors 2 and 4 both skip a file/value that matches the self-reference
exemption or the fixture-value heuristic below.

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

## Self-Reference Exemption (Detectors 2 + 4 only)

Security tooling must legitimately embed the same credential-shaped
regex/name literals it exists to detect — the scanner's own
`CRED_SHAPE_PATTERNS` array, or another script's copy of the same pattern
set, otherwise self-flags on every run. A file opts out by declaring this
exact marker anywhere in its **first 40 lines**:

```
# secret-exposure-scan: pattern-definitions
```

Detectors 2 and 4 then skip literal-value matching for that file only.
Detectors 1 (source-capture patterns) and 3 (permissions) are unaffected —
a security script is not exempt from being caught doing an unfiltered
environment dump.

An explicit opt-in marker is preferred over a hardcoded filename list: a
list silently goes stale as new scripts are added; a marker travels with
the file that needs it. `secret_exposure_scan.sh` itself carries the
marker (line 2). Any other script that defines the same credential-shaped
literals for detection purposes — e.g. `roborev_commit_msg_validator.sh` —
needs the marker added separately; it is not retrofitted automatically.

## Fixture-Value Heuristic (Detectors 2 + 4 only)

A matched literal is treated as an obviously-fake test/doc fixture — and
skipped — when its line contains (case-insensitive) `EXAMPLE`, `FAKE`,
`DUMMY`, `TEST`, `xxxx`, `AAAA`, `0000`, or a run of 8+ identical
characters.

This is a **value** heuristic, not a path heuristic: `tests/` is
deliberately never pruned by directory, because a real credential
accidentally committed to a test file must still be caught. A test file
whose fixture values do not carry one of these markers will still be
flagged — that is a prompt to add a marker to the fixture (e.g. rename
`ghp_abc123...` to `ghp_FAKE_abc123...` in the test), not a reason to widen
the rule.

```bash
# NOT a finding -- fixture-value heuristic (contains TEST + 0000)
api_token = "TEST_FAKE_0000000000000000"

# STILL a finding -- no fake marker, even though it's under tests/
api_token = "zK7wPlqRstUvWxYzAB12mQ9nR3sT"
```

## credential-assignment: NAME and VALUE (Detectors 2 + 4)

The original credential-assignment heuristic fired on **NAME alone**: any
substring match of `KEY|TOKEN|SECRET|PASSWORD|PASSWD|PAT|CREDENTIAL` in the
variable name, plus a value test that only checked "does not start with
`$`" — meaningless outside bash, and it treated `compat_mode` (contains
`PAT`), `date_key` (contains `KEY`), `KEYWORDS`, and `API_KEY_HEADER = "x-
api-key"` as credentials. On the llm repo this was ~89% of all detector-2
findings (295 of 331) at 2026-08 tuning, almost none of it real. The
heuristic now requires **BOTH**:

1. **`name_segment_matches`** — the name, split on `_`, `-`, `.`, and
   camelCase boundaries, has a whole SEGMENT (not substring) equal to
   `key`, `token`, `secret`, `password`, `passwd`, `pat`, `credential`, or
   `apikey`. `compat_mode` → `compat`,`mode` → no match. `date_key` →
   `date`,`key` → matches (name alone is still not sufficient — see below).
2. **`looks_like_credential_value`** — the VALUE itself looks
   credential-shaped:
   - ≥16 characters after extracting the actual literal (see "Value
     extraction" below)
   - contains at least one letter (excludes pure-numeric/date values)
   - not a `$VAR` reference, filesystem path, URL, template/placeholder
     (`{{`, `${`, `%s`, `<`, `>`), or code expression (contains `(`, `)`,
     `[`, `]`, or `,` — a Python/R `key_x = fn(a, b)` RHS is not a literal)
   - Shannon entropy (order-0, over the value's own character histogram)
     ≥ `CRED_ENTROPY_THRESHOLD` (**3.0** bits/char)

```bash
# NO finding -- name has no whole-word credential segment
compat_mode = "something"

# NO finding -- name matches ("key") but value is only 10 chars
date_key = "2026-08-13"

# NO finding -- name matches, value is only 9 chars
API_KEY_HEADER = "x-api-key"

# FINDING -- name matches, value is a real 16-char mixed-case+digit token
API_KEY = "aB3xK9mQ2pL7vN4t"

# FINDING -- 16-char ALL-LOWERCASE value, no digit at all
GMAIL_APP_PASSWORD = "wjqzxvkbmtynfcgh"
```

### Why no digit requirement

A real Gmail app password is 16 lowercase letters with **no digit** —
requiring a digit would silence exactly the kind of real secret this
scanner exists to catch. Entropy is the signal that actually separates a
random secret from dictionary/config text (common letters `e`,`t`,`a`,`o`,
`n` skew a natural-language string's character frequency well below
uniform, pulling its order-0 entropy under ~3 bits/char even in short
samples), and it works the same way whether the string mixes case+digits
or is pure lowercase. A digit-presence test was a bash-specific proxy that
never worked for `.py`/`.R` assignments in the first place (see the old
"Known residual noise" note below, now resolved).

### Value extraction

The coarse `ASSIGN_RE` grep can match a whole shell line, not just a bare
`NAME=value` pair — e.g. `HF_TOKEN='hf_xxx' hf auth whoami  # comment` (a
foreground env-assignment idiom) or `NAME="$OTHER_VAR"` (indirection).
`strip_assignment_value` extracts: the content between the FIRST matching
pair of quotes if the value is quoted (not "the rest of the line", which
would wrongly absorb `hf auth whoami # comment` into the value); otherwise
the first whitespace-delimited token. A quoted `"$OTHER_VAR"` still starts
with `$` after quote-stripping and is excluded by the `$VAR indirection`
check in `looks_like_credential_value` — quoting a variable reference does
not make it a literal.

## What `--fix` Will and Will Not Do

**Will** (safe, reversible, no data change): `chmod 600` a Detector-3-flagged file.

**Will not**: delete or rewrite any file automatically. Deleting a
credential file or a secret line is not a safe automatic action — a
human must confirm the value is genuinely dead before it is removed.
`--fix` prints the exact manual removal command instead. Detector-1
findings are never auto-rewritten — allowlist-vs-denylist is a judgement
call about which variables are actually needed downstream, not something
a script should guess.

## Pruned Paths (Performance + Noise)

`PRUNE_ARGS` excludes directories that only ever mirror a source file
already scanned elsewhere, or that are third-party/vendored, never
authored here: `.git`, `node_modules`, `_targets`, `worktrees`, `renv`,
`library`, `.quarto`, `_freeze`, `docs`, `libs`, `site_libs` — plus any
`*.min.js`/`*.map` file regardless of directory. A credential inside one
of these is a copy of one that exists in a source file we already scan;
pruning them removes noise without removing coverage.

Current state, after two tuning rounds (2026-08): the NAME-and-VALUE
credential-assignment check above (round 2) replaced an earlier name-only
substring heuristic that produced ~89% false positives on this repo;
`credential-assignment` findings dropped from 295 to 28 and total findings
from 421 to 67. Full before/after numbers, methodology, and the round-1
prune/dedup work that preceded it are in the companion doc, along with the
residual known-noise items (three scripts still needing the self-reference
marker added) deferred as a follow-up.

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
  `.claude/launchd/com.claude.secret-exposure-scan.plist`, currently
  running `--scan --quiet` (report-only) for a soak week before switching
  to `--fix --quiet` — see the plist comment for the promotion criterion.
- `--fast` scans the dotfile/config set only (skips the repo walk) for a
  session-start path; the full scan (default) is for the scheduled job.

## Heartbeat and Persistence (llm#951)

The flat log above only records `--fix` actions — a `--scan` run that finds
nothing (or that stops firing entirely) leaves no trace there, which is
exactly the `zero-metric-evidence-or-defect` failure mode: "0 findings"
becomes indistinguishable from "the scanner didn't run." Every `--scan`/
`--fix` invocation therefore also writes a heartbeat row to
`housekeeping_runs` and one row per finding to `secret_scan_findings` in
`~/.claude/logs/unified.duckdb` (override via `UNIFIED_DB_PATH`), following
`housekeeping-framework` — never a matched value, only the same
detector/file/line/name/note tuple the console report already shows. Both
writes fail open (`|| true`, never aborts the scan). Schema, idempotency
key, and selftest coverage are in the companion doc. The nightly digest
email reads this data to flag a rise in plaintext-credential findings or a
scanner that has gone silent for 48h.

## Verification

```bash
.claude/scripts/secret_exposure_scan.sh --selftest   # N/N PASS
.claude/scripts/secret_exposure_scan.sh --scan        # dry-run report
.claude/scripts/secret_exposure_scan.sh --fix          # safe remediation + report
```

### Measuring against a specific checkout

`REPO_ROOT` normally auto-detects from the scanner's own file location
(`git -C "$SCRIPT_DIR" rev-parse --show-toplevel`), so a copy of the script
running inside a worktree measures that worktree, not the main checkout —
relevant when tuning a detector and comparing before/after counts. Pin it
explicitly to measure a specific checkout regardless of where the script
itself lives:

```bash
REPO_ROOT=/absolute/path/to/checkout .claude/scripts/secret_exposure_scan.sh --scan
```

## Related

- [`_companions/secret-exposure-scanning-details.md`](_companions/secret-exposure-scanning-details.md)
  — full three-incident origin narrative, tuning-round history (round 1
  prune/dedup, round 2 NAME+VALUE redesign with before/after counts), and
  the DuckDB heartbeat/persistence implementation detail, split out of this
  rule
- `credential-management` rule — never embed credentials in R code; retrieve from environment
- `destructive-fs-guard` rule — hook-enforced guard for destructive filesystem ops (a different enforcement mechanism, same "advisory rules get ignored" motivation)
- `housekeeping-framework` rule — the launchd plist + log-table conventions this scan follows
