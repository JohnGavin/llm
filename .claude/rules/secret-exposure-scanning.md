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

Tuning note (2026-08, round 1): day-1 signal was 615 findings at ~5%
precision, dominated by vendored/minified JS (pdfmake.js × 3 copies across
`.quarto`, `_freeze`, `docs`), the scanner's own pattern definitions, and R
test fixtures using `=`-style keyword-argument assignment (`totalTokens =
tokens`) that trips the same `TOKEN=<literal>` shape as a real credential.
The prune list, self-reference exemption, and fixture-value heuristic above
address the first two; the third is addressed per-fixture via the
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
name-AND-value check in the "credential-assignment: NAME and VALUE" section
above. Measured against the main `llm` checkout (pinned via
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
(`.claude/scripts/secret_exposure_scan.sh` and this rule doc only).

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

- `credential-management` rule — never embed credentials in R code; retrieve from environment
- `destructive-fs-guard` rule — hook-enforced guard for destructive filesystem ops (a different enforcement mechanism, same "advisory rules get ignored" motivation)
- `housekeeping-framework` rule — the launchd plist + log-table conventions this scan follows
