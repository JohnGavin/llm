---
paths: ["**/.claude/scripts/private_data_*.sh", "**/.claude/scripts/private_values_sync.sh", "**/.claude/hooks/repo_visibility_guard.sh", "**/.github/workflows/private-data-scan.yml"]
---

# Rule: Private-Data Scanning (Mandatory Documentation of an Enforcement Chain)

## This rule is documentation. The enforcement is the scripts.

Nothing in this file blocks anything. `private_data_scan.sh` and its callers (git hooks, CI, the scheduled audit) do. This file exists so a human or a future agent can find the enforcement chain, understand why each layer exists, and know the exact commands to install or check it — the same "documentation vs enforcement" split as [`repo-visibility-gate`](repo-visibility-gate.md).

## Origin

2026-08-22. A personal phone number was found in this PUBLIC repo, in 8 files, across 9 commits, exposed for four months. Every existing control had been advisory or model-dependent — `.md` rules, an open issue naming the risk, an agent's own PII self-check, a manual review — and every one of them failed (full incident table: companion doc). The requirement this rule documents: enforcement must be running scripts, auto-triggered — not rules, memory, or `.md` files.

## The Five Layers

| Layer | What | File | Bypassable by |
|---|---|---|---|
| 1 | Scanner core (deny-list + generic patterns) | `.claude/scripts/private_data_scan.sh` | N/A — used by every other layer |
| 2 | pre-commit gate | installed by `.claude/scripts/private_data_git_hooks_install.sh` into `.git/hooks/pre-commit` | `git commit --no-verify` |
| 3 | pre-push gate | installed by the same installer into `.git/hooks/pre-push` | `git push --no-verify` |
| 4 | CI gate (PR) | `.github/workflows/private-data-scan.yml` | Nothing local — server-side, the layer that would actually have stopped the incident's merge |
| 5 | Scheduled full-history audit | `.claude/scripts/private_data_history_audit.sh` + `.claude/launchd/com.claude.private-data-history-audit.plist` (delivered, not installed) | N/A — report-only, catches what layers 2-4 could not have seen (pre-existing history) |

## CRITICAL: A check must prove it can fail before its "clean" is trusted

This repo configures **difftastic** as git's external diff driver, under which `git diff | grep '^+'` is vacuous ([JohnGavin/llm#997](https://github.com/JohnGavin/llm/issues/997)) — full hazard detail in companion doc. `private_data_scan.sh` is structurally immune: every content read goes through `git cat-file -p "<tree-ish>:<path>"`, never `git diff`/`git log -p`/`git show`; the remaining diff-family calls are name-only enumeration with `--no-ext-diff` belt-and-braces.

Beyond the structural fix, **every invocation, every mode, unconditionally** runs `assert_can_detect()` first: an in-process runtime assertion that feeds a known-bad synthetic fixture through the real detector functions and requires a hit, for both the generic-pattern detector and (when loaded) the deny-list detector. If either cannot detect its own known-bad fixture, the script aborts (exit 1) **before scanning anything real**. "Clean" is never reported by a detector that has not just proven, in this run, it is capable of reporting "dirty".

## Self-reference exemption scope

`SELF_REFERENCE_EXEMPT_FILES` in `private_data_scan.sh` is an exact relative-path array (never a glob/prefix) covering this scanner's own source files, so `assert_can_detect()`'s liveness probe and other synthetic self-test fixtures don't trip the scanner's own generic detector in CI. It applies to `scan_generic` **only** — `scan_denylist` runs unconditionally on every file including these two, verified by a dedicated selftest that plants a deny-list value in an "exempted" location and asserts it is still flagged. `assert_can_detect()`'s own probe uses a `"SELFCHECK"` label the exemption list does not match, so the liveness check itself stays un-exempted. A file this scanner does not own (e.g. `phi-scan-hook.sh`, from a different PR) is never added to this list — it gets the general-purpose EXAMPLE/FIXTURE marker instead. Full 2026-08-22 investigation (PR #1004): companion doc.

## Deny-list: a dedicated file, not `secrets.env` directly

The deny-list lives at `~/.config/private_values.env` (`KEY=value`, mode 600) — **not** `~/.config/secrets.env` — because `secrets.env` holds live credentials consumed by many other scripts, and coupling this scanner to it means every future scanner bug exposes everything, not just the handful of PII literals it needs. `.claude/scripts/private_values_sync.sh` extracts named keys (default `SIGNAL_ACCOUNT`, the value [llm#946](https://github.com/JohnGavin/llm/issues/946) flagged) from `secrets.env` into `private_values.env` — run manually, never auto-invoked: `bash .claude/scripts/private_values_sync.sh --dry-run` / `--apply`. Full rationale: companion doc.

## Relationship to `secret_exposure_scan.sh` (beside it, not inside it)

`secret_exposure_scan.sh` detects **credentials** via shape+entropy (high-entropy, `KEY`/`TOKEN`/`SECRET`-named). PII is the opposite shape — structured and **low-entropy** (phone numbers, postcodes, IBANs) — so the entropy heuristic never fires on it and there's no naming convention to anchor on; there's also no safe automatic `--fix` for PII baked into history, so remediation is always human judgement. Nothing is duplicated: `private_data_scan.sh` defines zero credential-shaped patterns. The two scanners share directory, the `housekeeping_runs` heartbeat convention, and CLI flag conventions — disjoint pattern sets. Full rationale: companion doc.

## Relationship to `repo_visibility_guard.sh` ([#976](https://github.com/JohnGavin/llm/pull/976))

`repo_visibility_guard.sh` is a **one-time gate** at the moment a repo becomes public. This rule's chain is the **ongoing** gate — the repo is already public, and new PII must never enter via a future commit/push/PR. Complementary, not competing. Merge/hardening detail: companion doc.

## CI's `--no-denylist` is a documented, narrower guarantee — not a gap

`.github/workflows/private-data-scan.yml` never has access to `~/.config/private_values.env` — a public repo's Actions runner must never be handed PII literals without an explicit opt-in. The workflow runs generic E.164/UK-postcode/IBAN pattern coverage only, and its own job summary says so. Opt-in path (maintainer decision, via a `PRIVATE_VALUES` repo secret): companion doc.

## Fail-closed (a deliberate divergence from this repo's usual hook convention)

`secret_leak_guard.sh`, `repo_visibility_guard.sh`, and every other `PreToolUse` guard in this repo fail **open** on internal error. `private_data_scan.sh` fails **closed**: a missing/unreadable deny-list (when required), an internal scanner error, or a failed self-check all exit non-zero — block, not allow. The two conventions are not in tension: `PreToolUse` guards protect an interactive session (wedging the agent has its own cost); this chain protects a publish boundary (commit → push → merge → live on a public repo), where a silent false "clean" is a permanent, indexable disclosure. This chain also deliberately ships **no** custom bypass env var — `git commit/push --no-verify` are git's own universal escape hatches, and CI has no `--no-verify` equivalent by design. Full rationale: companion doc.

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

Self-test: `bash .claude/scripts/private_data_history_audit.sh --selftest`. Manual run: `bash .claude/scripts/private_data_history_audit.sh` (requires `~/.config/private_values.env` — fails closed otherwise, same as every other local invocation).

## Remediation when the audit finds something

`private_data_scan.sh` and `private_data_history_audit.sh` never auto-remediate — there is no safe machine fix for PII already published. Follow [`repo-visibility-gate`](repo-visibility-gate.md)'s "The audit itself" section: read the flagged history, then orphan-squash / `git filter-repo` / accept-and-keep-private, and remember author/committer emails publish regardless of file content.

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

- [`repo-visibility-gate`](repo-visibility-gate.md) — the one-time private→public transition gate this rule's chain complements
- [`secret-exposure-scanning`](secret-exposure-scanning.md) — the sibling credential scanner this deliberately does not duplicate
- [`housekeeping-framework`](housekeeping-framework.md) — the dry-run/heartbeat/log pattern `private_data_history_audit.sh` follows
- [JohnGavin/llm#946](https://github.com/JohnGavin/llm/issues/946) — origin issue naming the SIGNAL_ACCOUNT phone-number risk
- [JohnGavin/llm#976](https://github.com/JohnGavin/llm/pull/976) — the repo-visibility guard this dispatch merged as its base
- [JohnGavin/llm#997](https://github.com/JohnGavin/llm/issues/997) — the difftastic vacuous-diff hazard this scanner is structurally immune to
- [JohnGavin/llm#1004](https://github.com/JohnGavin/llm/pull/1004) — this scanner's own CI run tripping its own generic detectors, resolved by the narrow `SELF_REFERENCE_EXEMPT_FILES` exemption above
