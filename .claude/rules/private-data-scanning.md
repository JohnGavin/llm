---
paths: ["**/.claude/scripts/private_data_*.sh", "**/.claude/scripts/private_values_sync.sh", "**/.claude/hooks/repo_visibility_guard.sh", "**/.github/workflows/private-data-scan.yml"]
---

# Rule: Private-Data Scanning (Mandatory Documentation of an Enforcement Chain)

## This rule is documentation. The enforcement is the scripts.

Nothing in this file blocks anything. `private_data_scan.sh` and its callers
(git hooks, CI, the scheduled audit) do. This file exists so a human or a
future agent can find the enforcement chain, understand why each layer
exists, and know the exact commands to install or check it — the same
"documentation vs enforcement" split as
[`repo-visibility-gate`](repo-visibility-gate.md).

## Origin

2026-08-22. A personal phone number was found in this PUBLIC repo, in 8
files, across 9 commits, exposed for four months. A history rewrite scrubbed
branches and tags. Every existing control had been advisory or
model-dependent, and every one of them failed:

| Control | How it failed |
|---|---|
| `.md` rules forbidding PII in public repos | Read, understood, and a PR containing the number was merged anyway |
| [llm#946](https://github.com/JohnGavin/llm/issues/946) naming this exact risk | Open for months; blocked nothing |
| An agent's own PII self-check | Swept for *billing* keywords, never a phone number; reported "clean" — truthfully, for what it checked |
| A careful manual check | Correct, but run on a different PR than the one that mattered |
| `secret_exposure_scan.sh` | Detects credentials, not PII — no phone pattern exists in it, by design |

The requirement this rule documents: enforcement must be running scripts,
auto-triggered — not rules, memory, or `.md` files, and not dependent on
someone remembering to run something.

## The Five Layers

| Layer | What | File | Bypassable by |
|---|---|---|---|
| 1 | Scanner core (deny-list + generic patterns) | `.claude/scripts/private_data_scan.sh` | N/A — used by every other layer |
| 2 | pre-commit gate | installed by `.claude/scripts/private_data_git_hooks_install.sh` into `.git/hooks/pre-commit` | `git commit --no-verify` |
| 3 | pre-push gate | installed by the same installer into `.git/hooks/pre-push` | `git push --no-verify` |
| 4 | CI gate (PR) | `.github/workflows/private-data-scan.yml` | Nothing local — server-side, the layer that would actually have stopped the incident's merge |
| 5 | Scheduled full-history audit | `.claude/scripts/private_data_history_audit.sh` + `.claude/launchd/com.claude.private-data-history-audit.plist` (delivered, not installed) | N/A — report-only, catches what layers 2-4 could not have seen (pre-existing history) |

## CRITICAL: A check must prove it can fail before its "clean" is trusted

This repo configures **difftastic** as git's external diff driver
(`diff.external = "difft --display inline"`, both globally and per-repo).
`git diff | grep '^+'` is therefore vacuous — difftastic's structural output
carries no `+`/`-` line prefixes, so the grep matches nothing regardless of
content and reports clean
([JohnGavin/llm#997](https://github.com/JohnGavin/llm/issues/997)). A PII
check is exactly the kind of check written ad-hoc, at the moment
reassurance is wanted, using `git diff | grep`.

`private_data_scan.sh` is structurally immune: every content read goes
through `git cat-file -p "<tree-ish>:<path>"` — a direct blob read, no diff
machinery, ever. It never calls `git diff` / `git log -p` / `git show
<commit>` for content. The only diff-family calls left are **name**
enumeration (`--name-only`, confirmed safe by #997's own investigation),
and even those pass `--no-ext-diff` belt-and-braces.

Beyond the structural fix, **every invocation, every mode, unconditionally**
runs `assert_can_detect()` first: an in-process runtime assertion that
feeds a known-bad synthetic fixture through the real detector functions and
requires a hit, for both the generic-pattern detector and (when loaded) the
deny-list detector. If either cannot detect its own known-bad fixture, the
script aborts (exit 1) **before scanning anything real**. "Clean" is never
reported by a detector that has not just proven, in this run, it is capable
of reporting "dirty".

## Self-reference exemption scope

**2026-08-22, [JohnGavin/llm#1004](https://github.com/JohnGavin/llm/pull/1004):**
this scanner's own CI run tripped its own generic detectors, scanning its
own source. Six findings, all synthetic: `assert_can_detect()`'s liveness
probe (`+19998887766`), the `RE_UK_POSTCODE` doc comment's example
postcodes, `private_values_sync.sh`'s selftest fixtures, and one doc
comment in `phi-scan-hook.sh` (unrelated file, arrived via #976).

The probe cannot carry an EXAMPLE/FIXTURE marker — that would exempt it
from the very detection it exists to prove (see `assert_can_detect()`'s own
comment). So a **different** mechanism than the general fixture-context
marker was needed, scoped to generic-pattern detection only:

- `SELF_REFERENCE_EXEMPT_FILES` in `private_data_scan.sh` — an exact
  relative-path array (`.claude/scripts/private_data_scan.sh`,
  `.claude/scripts/private_values_sync.sh`), never a glob or prefix. A new
  file does not silently inherit the exemption; adding one is a one-line,
  reviewable change.
- Applied in `scan_blob()` to `scan_generic` only. `scan_denylist` runs
  **unconditionally**, on every file including these two — a real leaked
  value sitting in this scanner's own source is still caught. Proved by a
  dedicated selftest case (plant a deny-list value in an "exempted"
  location, assert it is still flagged) — without that test the exemption
  would be an unproven hole, not a verified narrowing.
- `assert_can_detect()`'s own probe call uses the `"SELFCHECK"` location
  label, which the exemption list does not match — the liveness check
  itself stays un-exempted; this change does not weaken it.

**`phi-scan-hook.sh` was deliberately NOT added to this list.** It is not
part of this scanner's own source — it arrived via #976, is independently
maintained, and its own detection approach (plain grep patterns, no shared
code with this scanner) is unrelated. Coupling a file this scanner does not
own to a list titled "scanner sources and their selftests" would blur what
the list means and make it a more attractive place to quietly add
unrelated future exemptions. Instead it got a doc-comment fix: the word
"EXAMPLE" added to its postcode comment, which the *general-purpose*
fixture-context marker mechanism (`looks_like_fixture_context()`,
available to any file, not just this scanner's own) already recognises.
Same outcome, no special-casing, and the general mechanism is exercised by
a real file outside this scanner's control — evidence it actually works
for anyone, not just for this scanner's own maintainer.

## Deny-list: a dedicated file, not `secrets.env` directly

The deny-list lives at `~/.config/private_values.env` (`KEY=value`, mode
600) — **not** `~/.config/secrets.env`. Full rationale (blast radius,
schema coupling, wrong shape for the job) is in `private_data_scan.sh`'s
header comment. In short: `secrets.env` holds live credentials consumed by
many other scripts; coupling this scanner to it means every future bug in
the scanner exposes everything, not just the handful of PII literals it
needs.

`.claude/scripts/private_values_sync.sh` extracts named keys (default:
`SIGNAL_ACCOUNT` — the value
[llm#946](https://github.com/JohnGavin/llm/issues/946) flagged) from
`secrets.env` into `private_values.env`, so `secrets.env` stays the single
source of truth for the value while the scanner gets a narrow,
independently-permissioned file. Run it yourself — never auto-invoked:

```bash
bash .claude/scripts/private_values_sync.sh --dry-run
bash .claude/scripts/private_values_sync.sh --apply
```

## Relationship to `secret_exposure_scan.sh` (beside it, not inside it)

`secret_exposure_scan.sh` detects **credentials** via shape+entropy: a real
API key is high-entropy by construction, and its variable name follows
`KEY`/`TOKEN`/`SECRET` conventions. PII is the opposite shape — a phone
number, postcode, or IBAN is highly **structured and low-entropy** — the
entropy heuristic would never fire on it, and there is no
`PII_KEY_NAME=value` naming convention to anchor on. There is also no safe
automatic `--fix` for a phone number baked into history the way `chmod 600`
is for a world-readable dotfile — remediation is always human judgement, so
the `--fix` machinery does not transfer either. Nothing is duplicated:
`private_data_scan.sh` defines zero credential-shaped patterns and imports
none from `.claude/hooks/lib/cred_patterns.py`. The two scanners share
directory, the `housekeeping_runs` heartbeat convention, and the
`--json`/`--quiet`/`--selftest` flag conventions — but run over disjoint
pattern sets.

## Relationship to `repo_visibility_guard.sh` ([#976](https://github.com/JohnGavin/llm/pull/976))

`repo_visibility_guard.sh` is a **one-time gate** at the moment a repo
becomes public — it blocks the transition pending a manual history audit.
This rule's scanning chain is the **ongoing** gate: the repo is already
public, and new PII must never enter it via a future commit, push, PR, or
already-be-present-in-old-history. Complementary, not competing — see
`private_data_scan.sh`'s header for the full comparison, including the
pattern-set split (machine-reconnaissance disclosure vs. personal-identifier
disclosure).

This dispatch merged PR #976 as its base (rather than building a competing
mechanism) and hardened `_scan_history()` with `--no-ext-diff`,
belt-and-braces per #997's own recommendation — verified empirically that
this specific invocation was not actually vacuous on this repo's git
version (byte-identical output with/without the flag), but the safety
margin costs nothing and a future difftastic version/config is not
guaranteed to render the same way.

## CI's `--no-denylist` is a documented, narrower guarantee — not a gap

`.github/workflows/private-data-scan.yml` never has access to
`~/.config/private_values.env` — a public repo's Actions runner must never
be handed personal PII literals, even as a masked secret, without an
explicit opt-in. The workflow runs with generic E.164/UK-postcode/IBAN
pattern coverage only, and its own job summary says so — it never silently
presents itself as the deny-list's stronger guarantee.

**To opt in later** (maintainer decision, not made by this rule or by any
agent): add a repository secret `PRIVATE_VALUES` containing the same
`KEY=value` lines as `private_values.env`, then extend the workflow to
write it to a runner-local file and pass `--require-denylist` instead of
`--no-denylist`. GitHub Actions secrets are not exposed to workflows
triggered by fork PRs by default, which is the right default here — a
malicious fork PR would not have the value anyway; a legitimate
maintainer-authored PR (the scenario that actually failed) would still be
covered once opted in.

## Fail-closed (a deliberate divergence from this repo's usual hook convention)

`secret_leak_guard.sh`, `repo_visibility_guard.sh`, and every other
`PreToolUse` guard in this repo fail **open** on internal error — "a broken
guard must never wedge a session." `private_data_scan.sh` fails **closed**:
a missing/unreadable deny-list (when required), an internal scanner error,
or a failed self-check all exit non-zero — block, not allow.

The two conventions are not in tension. `PreToolUse` guards protect an
interactive session, where wedging the agent has its own cost. This chain
protects a publish boundary — commit → push → merge → live on a public
repo — where the cost of a silent false "clean" is a permanent, indexable
disclosure. A blocked commit is recoverable (fix the error, retry, or use
`--no-verify`); a merged PII leak is not.

### Why no custom bypass env var

Every other guard in this repo ships a documented kill-switch
(`SECRET_GUARD_BYPASS=1`, `REPO_PUBLIC_OK=1`, `SKIP_RULE_SCOPING=1`, …).
This chain deliberately does not add one. `git commit --no-verify` and `git
push --no-verify` are git's own, universally-known escape hatches and
cannot be prevented by any hook regardless — inventing a second,
scanner-specific bypass alongside them would add a second thing to keep in
sync with the fail-closed posture, for zero additional capability (anyone
who can run `--no-verify` already has the override). CI has no `--no-verify`
equivalent by design — that absence is the point of Layer 4.

## Installing the hooks (manual — never auto-installed)

```bash
# Preview first
bash .claude/scripts/private_data_git_hooks_install.sh --dry-run --hook both

# Install into the CURRENT repo's .git/hooks (chains existing pre-commit /
# pre-push content -- does not overwrite it)
bash .claude/scripts/private_data_git_hooks_install.sh --install --hook both

# Verify
bash .claude/scripts/private_data_git_hooks_install.sh --selftest

# Uninstall (restores the pre-existing hook from its .pre-privatedata.bak)
bash .claude/scripts/private_data_git_hooks_install.sh --uninstall --hook both
```

## Installing the scheduled audit (manual — never auto-installed)

```bash
launchctl bootout gui/$(id -u)/com.claude.private-data-history-audit 2>/dev/null
cp .claude/launchd/com.claude.private-data-history-audit.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.claude.private-data-history-audit.plist
```

Self-test: `bash .claude/scripts/private_data_history_audit.sh --selftest`.
Manual run: `bash .claude/scripts/private_data_history_audit.sh` (requires
`~/.config/private_values.env` — fails closed otherwise, same as every
other local invocation).

## Remediation when the audit finds something

`private_data_scan.sh` and `private_data_history_audit.sh` never
auto-remediate — there is no safe machine fix for PII already published.
Follow [`repo-visibility-gate`](repo-visibility-gate.md)'s "The audit
itself" section: read the flagged history, then orphan-squash / `git
filter-repo` / accept-and-keep-private, and remember author/committer
emails publish regardless of file content.

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---|---|---|
| Trusting a "clean" result from a scanner that has not proven it can fail this run | The exact failure mode of 2026-08-22 and #997 | `assert_can_detect()` runs unconditionally — do not add a flag to skip it |
| Using `git diff \| grep` (or any diff/log -p/show output) to check content | Vacuous under this repo's difftastic config | Use `private_data_scan.sh`, or at minimum `--no-ext-diff` |
| Pointing the scanner at `secrets.env` directly | Recreates the blast-radius/coupling problem this design avoids | Sync named keys via `private_values_sync.sh` |
| Adding PII regex patterns inside `secret_exposure_scan.sh` | Different math (structured/low-entropy vs random/high-entropy), different remediation model | Keep them beside each other, as here |
| Adding a `PRIVATE_DATA_SCAN_BYPASS=1` env var | Duplicates `--no-verify` for no new capability | Use git's own `--no-verify` |
| CI silently presenting `--no-denylist` results as a full guarantee | Understates what was actually checked | The workflow prints its own scope in its job summary — keep that line |
| Adding an EXAMPLE/FIXTURE marker to `assert_can_detect()`'s probe to quiet a self-scan finding | Exempts the probe from the very detection it exists to prove | Use `SELF_REFERENCE_EXEMPT_FILES` (generic-only, deny-list still fires) instead |
| Widening `SELF_REFERENCE_EXEMPT_FILES` to a glob/prefix, or adding a file this scanner does not own to it | Silent inheritance by future files; blurs what the list means | Exact paths only; unrelated files (e.g. `phi-scan-hook.sh`) get the general-purpose EXAMPLE marker instead |
| Exempting a self-reference file from `scan_denylist` too | A real leaked value inside the scanner's own source would go uncaught | Only `scan_generic` is gated by `is_self_reference_exempt()` — verified by a dedicated selftest case |

## Related

- [`repo-visibility-gate`](repo-visibility-gate.md) — the one-time
  private→public transition gate this rule's chain complements
- [`secret-exposure-scanning`](secret-exposure-scanning.md) — the sibling
  credential scanner this deliberately does not duplicate
- [`housekeeping-framework`](housekeeping-framework.md) — the
  dry-run/heartbeat/log pattern `private_data_history_audit.sh` follows
- [JohnGavin/llm#946](https://github.com/JohnGavin/llm/issues/946) — origin
  issue naming the SIGNAL_ACCOUNT phone-number risk
- [JohnGavin/llm#976](https://github.com/JohnGavin/llm/pull/976) — the
  repo-visibility guard this dispatch merged as its base
- [JohnGavin/llm#997](https://github.com/JohnGavin/llm/issues/997) — the
  difftastic vacuous-diff hazard this scanner is structurally immune to
- [JohnGavin/llm#1004](https://github.com/JohnGavin/llm/pull/1004) — this
  scanner's own CI run tripping its own generic detectors, resolved by the
  narrow `SELF_REFERENCE_EXEMPT_FILES` exemption above
