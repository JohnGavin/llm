---
paths: ["**/.claude/hooks/repo_visibility_guard.sh", "**/.claude/settings.json"]
---

# Rule: Repo Visibility Gate (private → public)

## When This Applies

Any command that makes a git repository public:

- `gh repo create … --public`
- `gh repo edit … --visibility public`
- `gh api … -f visibility=public` (or `--field visibility=public`)

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

`~/.claude/hooks/repo_visibility_guard.sh` (`PreToolUse:Bash`) blocks the
transition with exit 2. It scans **all reachable history** (`git log --all -p`,
bounded by byte cap and timeout) for privacy patterns — home paths, `~/Downloads`
/`~/Desktop`/`~/Documents`, `.Trash`, Time Machine / `tmutil`,
`Library/Application Support`, "irreplaceable", and email addresses — and prints
what it found.

It deliberately does **not** duplicate credential shapes; those stay owned by
`secret_leak_guard.sh` and `lib/cred_patterns.py`, per llm#958.

Bypass, after the audit is genuinely done:

```bash
REPO_PUBLIC_OK=1 gh repo create <name> --public
```

Log: `~/.claude/logs/repo_visibility_guard.log` (one line per block or bypass).
Self-test: `bash repo_visibility_guard.sh --selftest` → 10/10 expected.

## The audit itself

The hook's pattern scan is a **denylist**. It proves absence of known-bad
patterns, not absence of all confidential content. Do these before bypassing:

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
| `REPO_PUBLIC_OK=1` reflexively to clear the block | Defeats the gate entirely | Only after step 1-3 are actually done |
| Treating a clean pattern scan as proof | Denylists prove nothing about unknown content | Human-read the prose files |
| Committing session-handoff / machine-survey docs into a project repo | They are written under a private assumption that may not hold later | Keep machine reconnaissance out of tracked files, or gitignore the handoff doc |
| Auditing HEAD only | The incident content was absent from the working tree | `git log --all -p` |

## Related

- [`secret-leak-prevention`](secret-leak-prevention.md) — credential splicing into Bash commands
- [`human-in-the-loop-decision-points`](human-in-the-loop-decision-points.md) — a visibility flip is a publish gate (Class C): explicit action verb required, never a bare "yes"
- [`pr-shipping-discipline`](pr-shipping-discipline.md) — same instinct applied to merges
- `~/.claude/CLAUDE.md` **Data Privacy** — PHI/confidential data never to public repos without approval; this rule is the mechanical enforcement of that line
