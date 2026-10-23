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

## Document formats, root commits and non-UTF-8 blobs ([#1358](https://github.com/JohnGavin/llm/issues/1358))

Three blind spots were closed. Byte filtering and matching run under `LC_ALL=C` inside the script, so a blob that is not valid UTF-8 is scanned the same whatever `LANG` the caller has (a UTF-8 shell saw a PDF as 10 bytes instead of 394,065, so interactive and launchd runs disagreed). `git diff-tree` now passes `--root`, so files added in a repository's first commit are scanned by `--full-history` and `--range`.

Document formats (`pdf`, `docx`, `xlsx`, `doc`, `xls`, `odt`, `rtf`, `eml`, `msg`, `eps`, `ps`; EPS = Encapsulated PostScript, PS = PostScript, llm#1436) keep their text in a layer the byte-level rules cannot read. In a **public** repo the scanner therefore blocks them at every layer (pre-commit, pre-push, CI, history audit) with a critical `document-format-blocked` finding unless the path is on `.claude/private_data_document_allowlist.txt`. Unknown visibility counts as public. In `--full-history` the same condition is reported as its own rule, `document-format-in-public-history`, because the generic regexes miss it. Each allow-list line is `<exact repo-relative path> | <reason>`; a line without a reason, or with a glob-style path, allows nothing. Default-permit is fail-open, so the list starts empty. One home per value: the document list is `DOC_FORMAT_EXTS` and the image list `IMAGE_EXTS` in `private_data_scan.sh` (the import guard reads both at run time and has no fallback copy; an unreadable scanner makes it block as INDETERMINATE), the archive list is `ARCHIVE_EXTS` in the guard; `one_home_ext_lists_check.sh` fails on any other literal copy not on `.claude/state/one_home_ext_lists_allowlist.txt` (every entry states a reason).

PDFs are also text-extracted with `pdftotext` (poppler) and the text is run through the deny-list and the generic rules, in public and private repos alike. If the extractor is missing, fails, or finds no text layer, that file was not inspected: the run exits 3 (INDETERMINATE) when it found nothing else, never 0. Other formats have no extractor; for them the allow-list entry is the human acceptance of the file as a whole. CI installs `poppler-utils` before its selftest, which itself exits 3 if the extractor is absent.

## Filename and image gates ([#1369](https://github.com/JohnGavin/llm/issues/1369), [#1370](https://github.com/JohnGavin/llm/issues/1370))

Two path-level rules cover what no text rule can see: a file whose NAME says what it is, and a photo or screenshot of a letter. Both run in `scan_blob`, so they apply in every mode (`--staged` for pre-commit, `--range` for pre-push and CI, `--full-history`, `--paths`), only in a **public** repo (unknown visibility counts as public), and both lift on the same exact-path allow-list as the document gate (`.claude/private_data_document_allowlist.txt`, `<path> | <reason>`; no reason, no allowance). Findings carry the path and, for images, the size in bytes — never content.

**`sensitive-filename` (critical).** The path is lower-cased and split into tokens on every character outside `a-z0-9`, so word boundaries are exact (`ipaddress` is not `address`, `taxonomy` is not `tax`, `clinical` is not `clinic`); trailing digits are stripped (`payslip2024`). Two lists, both in `private_data_scan.sh`:

| List | Words | Counts when |
|---|---|---|
| Strong | nhs, hospital, clinic, payslip(s), p60, p45, p11d, passport, discharge, prescription | any path segment, any extension |
| Broad | letter(s), statement(s), invoice(s), tax(es), bank, licence/license, contact(s), address, medical, salary, payroll, mortgage, appointment(s), referral | only when the file extension is a document, image or plain-data type (pdf doc docx xls xlsx odt ods rtf eml msg csv tsv txt png jpg jpeg gif heic heif tif tiff bmp webp) |

Broad words are everyday code identifiers (`tax.R`, `statement.sql`, `address.pyi`), so a source or markup extension never counts. `signal` is deliberately absent: it is a Python module and a messaging app, and was the noisiest word tried. Tuning evidence on the 2026-10-11 inventory of the owner's public repos (17,949 added-path rows; counts only): a substring match on the words fired on 712 rows, an exact word-boundary match on 212, the shipped rule (strong anywhere, broad on document/image/data extensions) on 17, all of them document-like or strongly named. This repo's own tracked files: 0 hits. Changing a list means repeating that count and recording before/after here.

**`image-outside-figures` (critical in `--staged`, `--range`, `--paths`; reported as `image-in-public-history`, severity high, in `--full-history`).** Image extensions (png jpg jpeg gif webp heic heif tif tiff bmp; a pure-vector `svg` (SVG = Scalable Vector Graphics) is text and is scanned as text, but an SVG that embeds a raster (`data:image/` URI, or an `<image>` element whose href is a raster file) is treated exactly like a PNG, and an unreadable SVG is INDETERMINATE, llm#1436) are blocked unless the path is in a generated-figure folder: `man/figures/`, `docs/` and `vignettes/<x>_files/` (all anchored at the repo root, so `notes/docs/scan.jpg` is still blocked), `<x>_files/figure-*/` and `_freeze/`, `_site/` at any depth. History gets its own lower-severity rule so that historic plots do not flood the alert channel: on the inventory, 1,528 image rows exist, 182 sit in generated folders and 1,346 would fire. The audit's per-finding baseline absorbs them. "New" images in pre-commit are staged additions and modifications; an image that must live outside the folders goes on the allow-list with a reason.

Both rules have selftests with synthetic repos for fires / does not fire / allow-listed / private, and each was falsified (emptying the word lists, or the image extension list, silences the rule; restoring it brings the finding back).

## Copy-time guard: `public_repo_file_import_guard.sh` ([#1368](https://github.com/JohnGavin/llm/issues/1368))

The scanner layers above fire at commit time. This `PreToolUse` hook (Bash and Write) fires earlier, at the moment a file is put into a public repo's working tree, which is how a private document normally arrives (a copy from Downloads, Desktop, iCloud or a private repo). On Bash it reads the destination of `cp`, `mv`, `rsync`, `ditto`, `install` and `git add` (globs expanded, directories walked, `cd X &&` and `git -C X` followed; `git add .` / `-A` check the untracked files); on Write it reads `file_path`.

It exits 2 (and prints a `permissionDecision: "deny"` body) when the destination is inside a git working tree whose visibility is `public` **or unknown** (a failed lookup is treated as public), and the file is a document format (the scanner's `DOC_FORMAT_EXTS`), an archive, or an image outside the generated-figure folders (`man/figures`, `*_files/figure-html`, `docs/`, `_freeze/`, `pkgdown/`), unless the exact repo-relative path is on that repo's `.claude/private_data_document_allowlist.txt` (`<path> | <reason>`, the same file and parser rules as the scanner). A destination outside any git repo is never blocked, and an already-tracked file passed to `git add` is not re-blocked.

Limits, stated so the gap is not mistaken for coverage: redirections and `tee`, `ditto -x`, archives unpacked by `tar`/`unzip`, and paths built from shell variables are not followed; a rename of a document inside a public repo is blocked like an import. A parser crash (no `python3`) fails open and is logged to `~/.claude/logs/public_repo_file_import_guard.log`; only the visibility lookup fails closed. Test: `bash .claude/hooks/public_repo_file_import_guard.sh --selftest` (synthetic repos, stubbed lookup, falsification cases).

## Deny-list: a dedicated file, not `secrets.env` directly

The deny-list lives at `~/.config/private_values.env` (`KEY=value`, mode 600) — **not** `~/.config/secrets.env` — because `secrets.env` holds live credentials consumed by many other scripts, and coupling this scanner to it means every future scanner bug exposes everything, not just the handful of PII literals it needs. `.claude/scripts/private_values_sync.sh` extracts named keys (default `SIGNAL_ACCOUNT`, the value [llm#946](https://github.com/JohnGavin/llm/issues/946) flagged) from `secrets.env` into `private_values.env` — run manually, never auto-invoked: `bash .claude/scripts/private_values_sync.sh --dry-run` / `--apply`. Full rationale: companion doc.

## Relationship to `secret_exposure_scan.sh` (beside it, not inside it)

`secret_exposure_scan.sh` detects **credentials** via shape+entropy (high-entropy, `KEY`/`TOKEN`/`SECRET`-named). PII is the opposite shape — structured and **low-entropy** (phone numbers, postcodes, IBANs) — so the entropy heuristic never fires on it and there's no naming convention to anchor on; there's also no safe automatic `--fix` for PII baked into history, so remediation is always human judgement. Nothing is duplicated: `private_data_scan.sh` defines zero credential-shaped patterns. The two scanners share directory, the `housekeeping_runs` heartbeat convention, and CLI flag conventions — disjoint pattern sets. Full rationale: companion doc.

## Relationship to `repo_visibility_guard.sh` ([#976](https://github.com/JohnGavin/llm/pull/976))

`repo_visibility_guard.sh` is a **one-time gate** at the moment a repo becomes public. This rule's chain is the **ongoing** gate — the repo is already public, and new PII must never enter via a future commit/push/PR. Complementary, not competing. Merge/hardening detail: companion doc.

## CI's `--no-denylist` is a documented, narrower guarantee — not a gap

`.github/workflows/private-data-scan.yml` never has access to `~/.config/private_values.env` — a public repo's Actions runner must never be handed PII literals without an explicit opt-in. The workflow runs generic E.164/UK-postcode/IBAN pattern coverage only, and its own job summary says so. Opt-in path (maintainer decision, via a `PRIVATE_VALUES` repo secret): companion doc.

## Fail-closed (a deliberate divergence from this repo's usual hook convention)

`secret_leak_guard.sh` and every other `PreToolUse` guard in this repo except `repo_visibility_guard.sh` (fail **closed** for visibility commands since llm#1392) fail **open** on internal error. `private_data_scan.sh` fails **closed**: a missing/unreadable deny-list (when required), an internal scanner error, or a failed self-check all exit non-zero — block, not allow. The two conventions are not in tension: `PreToolUse` guards protect an interactive session (wedging the agent has its own cost); this chain protects a publish boundary (commit → push → merge → live on a public repo), where a silent false "clean" is a permanent, indexable disclosure. This chain also deliberately ships **no** custom bypass env var — `git commit/push --no-verify` are git's own universal escape hatches, and CI has no `--no-verify` equivalent by design. Full rationale: companion doc.

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

### Per-finding baseline (new vs known)

Full history holds hundreds of long-standing findings, so the audit tracks each one by a value-free fingerprint (`sha256(repo|rule|src|<sha12>:<path>|line)`) in the local-only table `private_data_history_findings` (`unified.duckdb`; apply with `housekeeping_schema_apply.sh`). Only **new** fingerprints alert; known ones are summarised by `(rule, src, count)`.

| Exit | Meaning |
|---|---|
| 0 | ran; no NEW finding (known/acknowledged may exist; the log line says how many) |
| 1 | ran; at least one NEW finding |
| 2 | usage error (bad flag, `--ack` matching nothing or malformed) |
| 3 | INDETERMINATE: scanner missing/crashed/truncated, DB or table unusable, or no baseline yet |

One-time seed after deploy: `bash .claude/scripts/private_data_history_audit.sh --baseline` (marks every current finding `known`). Triage a reported finding with `--ack <fingerprint-prefix>` or `--ack-file <file>`. `private_data_scan.sh` itself still exits 1 for both findings and fail-closed errors (hooks block on any non-zero); the audit wrapper tells them apart by requiring the scanner's `N finding(s)` summary line. Generic shape rules are skipped for known-binary blobs (`.rds`, fonts, images, archives, `*.min.js`); the deny-list still runs on every blob, and PDFs stay scanned.

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
