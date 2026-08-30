# Companion: Private-Data Scanning — Origin Incident, Self-Reference Exemption Investigation, and Merge Detail

Dated incident narrative and verbose investigation detail split out of the
always-loaded [`private-data-scanning`](../private-data-scanning.md) rule to
keep it under the repo's line-count budget. The normative content ("This
rule is documentation" statement, The Five Layers table, the
`assert_can_detect()` CRITICAL statement, the self-reference exemption
mechanism summary, deny-list architecture, relationship summaries,
fail-closed posture, installation commands, Forbidden Patterns table,
Related) stays in the rule; this file is the full origin narrative and
dated investigation detail, loaded on demand.

## Origin — full incident detail

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

## The difftastic vacuous-diff hazard, full detail

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

## Self-reference exemption scope — full investigation (2026-08-22, PR #1004)

This scanner's own CI run tripped its own generic detectors, scanning its
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

## Deny-list architecture — full rationale

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

## Relationship to `secret_exposure_scan.sh`, full rationale

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

## Relationship to `repo_visibility_guard.sh` — merge detail ([#976](https://github.com/JohnGavin/llm/pull/976))

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

## CI's `--no-denylist` — full opt-in detail

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

## Why no custom bypass env var — full rationale

Every other guard in this repo ships a documented kill-switch
(`SECRET_GUARD_BYPASS=1`, `REPO_PUBLIC_OK=1`, `SKIP_RULE_SCOPING=1`, …).
This chain deliberately does not add one. `git commit --no-verify` and `git
push --no-verify` are git's own, universally-known escape hatches and
cannot be prevented by any hook regardless — inventing a second,
scanner-specific bypass alongside them would add a second thing to keep in
sync with the fail-closed posture, for zero additional capability (anyone
who can run `--no-verify` already has the override). CI has no `--no-verify`
equivalent by design — that absence is the point of Layer 4.
