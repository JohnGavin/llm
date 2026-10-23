---
paths: ["**/.claude/hooks/repo_visibility_guard.sh", "**/.claude/scripts/repo_publish_audit.sh", "**/.claude/settings.json"]
---

# Rule: Repo Visibility Gate (private → public)

## When This Applies

Any command that makes a git repository public:

- `gh repo create … --public`
- `gh repo edit … --visibility public`
- `gh api … -f visibility=public` (or `-F` / `--field`)

## CRITICAL: Publishing a repo publishes its ENTIRE history

The current tree is not the disclosure surface. Every reachable commit on every
ref is published, permanently and indexably. Content that was perfectly safe
while a repo was private becomes a disclosure the instant visibility flips —
and **nothing re-evaluates old commits when the privacy assumption changes.**

> A repo's privacy classification is a property of *now*. Its history is a
> property of *forever*. Audit the second before changing the first.

## Origin

2026-08-18, `JohnGavin/procedural-scenes`. A session-handoff doc committed a
week earlier (`.claude/CURRENT_WORK.md`) recorded a disk survey performed to
free space for Blender: personal folder names ("100GOPRO … personal
irreplaceable footage"), media-library sizes, APFS Time Machine snapshot counts,
and local model caches (lm-studio, ollama, whisper, nomic, solana).

That was reasonable when written — the repo was local-only with no remote, so
the doc was private notes. It became a disclosure when the repo was made public.

**It was caught only because the assistant chose to grep before publishing.**
No hook fired. That dependency on remembering is the defect this rule fixes.

Why the existing guards did not cover it:

| Hook | Scope | Caught it? |
|---|---|---|
| `secret_leak_guard.sh` | command-substitution splicing credentials into a Bash call | No — different failure mode |
| `artifact_secret_guard.sh` | Artifact publishing | No — not git |
| `phi-scan-hook.sh` | Write/Edit PHI patterns | No — and it was not wired into `settings.json` at all |

## Enforcement

`~/.claude/hooks/repo_visibility_guard.sh` (`PreToolUse:Bash`, rebuilt in
[#1392](https://github.com/JohnGavin/llm/issues/1392)) blocks (exit 2) every
private → public command unless a **fresh clean audit of exactly what would be
published** is on record:

- **Forms covered:** `gh repo edit [REPO] --visibility V` (flag anywhere,
  `--accept-visibility-change-consequences`), `gh api repos/O/R` with a
  `visibility` field or an `--input` body, `gh repo create|new` with `--public`
  **or with no visibility flag** (gh does not default to private), inside
  `bash -c`, `eval`, `$(...)`, `xargs`, `env`, `sudo` and compound lists. A value
  that is not literally `private`/`internal` counts as public. Target = the
  command, else the working directory's origin; a target that is not the clone in
  the working directory is INDETERMINATE.
- **Fresh audit:** `repo_publish_audit.sh --record --repo O/R --dir DIR` runs
  `private_data_scan.sh --full-history` as a public repo (private-term rule,
  deny-list, document and image gates; zero findings is the bar — a "known"
  finding still publishes) and records the result in the ledger table
  `private_data_history_unit_state` under `publish:O/R`. The hook allows only if
  the record is clean, younger than 24 h (`REPO_PUBLISH_AUDIT_MAX_AGE_HOURS`) and
  made for the current fingerprint of **every ref** (a new commit, branch or tag
  voids it), with the same deny-list, term list and scanner.
- **Fail closed, visibility commands only:** any error (no ledger, unreadable or
  locked ledger, term list or deny-list missing/empty/stale, audit script, parser,
  `python3`, timeout, crash) BLOCKS as `INDETERMINATE`. Other Bash commands never
  reach the slow path. Messages and the log never contain matched text or terms.
- **Only override:** the owner creates `~/.config/repo_public_ack/<owner>__<repo>`
  (`gh repo create`: the name as typed; with no `--source`, content
  `no-local-source`) containing the exact tip fingerprint the block message
  prints, so it expires on any new commit. **An assistant must never create it**;
  the hook never does. `REPO_PUBLIC_OK=1` no longer does anything.
- **Limit:** a flip in the GitHub web UI or by another client cannot be hooked
  locally. `repo_visibility_diff.sh` (daily,
  [#1371](https://github.com/JohnGavin/llm/issues/1371)) detects it afterwards and
  audits the repo as public; its finding reaches the 06:30 email.

Log: `~/.claude/logs/repo_visibility_guard.log`. Self-test:
`bash repo_visibility_guard.sh --selftest` (20 cases). Acceptance and
falsification: `bash tests/test_repo_visibility_gate.sh`.

## The audit itself

The scan is a **denylist**. It proves absence of known-bad patterns, not absence
of all confidential content. Do these before acknowledging:

1. **Read the history**: `git log --all -p | less`. Prose files (READMEs,
   CHANGELOGs, handoff docs, comments) are where the risk lives; generated code
   rarely carries PII.
2. **Choose a remedy** rather than accepting the history as-is:
   - **squash to a clean orphan commit** (`git checkout --orphan`) — publishes
     current state only; history stays local and nothing is destroyed;
   - **scrub** with `git filter-repo` — preserves the narrative, fiddlier;
   - **publish private** — gets the work backed up with zero disclosure.
3. **Check metadata.** Author and committer emails are published regardless of
   file content: `git log --all --format='%ae' | sort -u`. Use a GitHub noreply
   address if that matters.
4. **Verify from the remote side afterwards**, not just locally:
   ```bash
   git ls-remote origin                      # any ref beyond main carries extra history
   gh api repos/O/R/commits --jq length      # commit count
   gh api repos/O/R/commits/main --jq '.parents|length'   # 0 = orphan, no prior history
   ```
   An orphan single commit means published history *is* the published tree —
   there is no hidden surface, which is a far stronger guarantee than any grep.

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---|---|---|
| Making a repo public without reading its history | History is the disclosure surface, not HEAD | Run the audit above |
| An assistant creating the acknowledgement file or editing the ledger row | Forges the owner's decision | Only the owner creates `repo_public_ack/*`; run the audit instead |
| Treating a clean pattern scan as proof | Denylists prove nothing about unknown content | Human-read the prose files |
| Committing session-handoff / machine-survey docs into a project repo | They are written under a private assumption that may not hold later | Keep machine reconnaissance out of tracked files, or gitignore the handoff doc |
| Auditing HEAD only | The incident content was absent from the working tree | `git log --all -p` |

## Related

- [`secret-leak-prevention`](secret-leak-prevention.md) — credential splicing into Bash commands
- [`human-in-the-loop-decision-points`](human-in-the-loop-decision-points.md) — a visibility flip is a publish gate (Class C): explicit action verb required, never a bare "yes"
- [`pr-shipping-discipline`](pr-shipping-discipline.md) — same instinct applied to merges
- `~/.claude/CLAUDE.md` **Data Privacy** — PHI/confidential data never to public repos without approval; this rule is the mechanical enforcement of that line
