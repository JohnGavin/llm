# Incident: full environment dumped to a public GitHub comment

**Date:** 2026-08-11
**Severity:** Catastrophic — 14 credential-bearing variables published to a public repository
**Actor:** Claude Code orchestrator session (this assistant)
**Status:** Contained. Rotation in progress. Prevention landed under llm#791 follow-ups.

> This document contains **no credential values**. Every reference is by variable
> name only. Do not paste values into this file when updating it.

---

## 1. What happened

While commenting on a public issue in `JohnGavin/llm`, the assistant ran:

```
gh issue comment <N> --body "… `printenv` …"
```

The `--body` argument was a **double-quoted shell string**. Backticks inside a
double-quoted string are command substitution, performed by the shell *before*
`gh` is executed. The shell ran `printenv`, which with no argument prints the
entire environment, and spliced the result into the comment body.

92 environment variables were published, of which **14 carried live
credentials**. The comment was on a public repository and was therefore
world-readable and immediately indexed by secret scanners.

## 2. Blast radius (verified, not estimated)

| Question | Method | Result |
|---|---|---|
| How many comments affected? | Scanned 100 most recent comments for the marker pattern | **1** |
| How many issue bodies affected? | Scanned 60 issue bodies | **0** |
| How many env vars published? | Counted in the rendered comment | **92** |
| How many were credentials? | Cross-referenced against `~/.config/secrets.env` + live env | **14** |

The 14: `AlphaVantage_API_KEY`, `CACHIX_AUTH_TOKEN`, `ELEVENLABS_API_KEY`,
`FRED_API_KEY`, `GEMINI_API_KEY`, `GH_TOKEN`, `GITHUB_PAT`,
`GMAIL_APP_PASSWORD`, `GOOGLE_API_KEY`, `GUARDIAN_API`, `HF_TOKEN`,
`HUGGING_FACE_HUB_TOKEN`, `HUGGINGFACE_API_TOKEN`, `OPENAI_API_KEY`.

Provider responses received within hours: Google Cloud key deleted, GitHub PAT
revoked, HuggingFace token expired, OpenAI key disabled, GitHub secret-scanning
alert raised naming 5 secret types.

## 3. Contributing failures, in causal order

1. **A secret was printed to the transcript two days earlier (08-09).** The
   assistant ran an is-it-set check of the form `${VAR:+SET}${VAR:-UNSET}`.
   The `:-` branch expands to the *value* when the variable is set. This exact
   construct is listed as forbidden, with the correct alternative, in
   `credential-management.md`.

2. **A secrets migration converted three shell-local assignments to `export`.**
   `GMAIL_APP_PASSWORD`, `FRED_API_KEY` and `AlphaVantage_API_KEY` had been
   unexported and were therefore **invisible to `printenv`**. They became
   visible roughly one hour before the dump.

3. **An identical command-substitution failure occurred earlier and was
   misclassified.** A prior `gh issue comment` had its `KeepAlive` text mangled
   by the same mechanism. The assistant repaired the *text* using
   `--body-file` and did not ask why the text had changed. The single available
   warning was consumed without being understood.

4. **The dump.** As described in §1.

## 4. Why the governing rule did not fire

`credential-management.md` documents the anti-pattern in (1) verbatim, with the
fix. It never entered context, because its frontmatter scopes it:

```yaml
paths: ["**/.Renviron*", ".github/**", "R/**"]
```

The work was in `.claude/scripts/*.sh`, `~/.zshenv`, `~/.config/secrets.env`
and launchd plists. **None of those match.** The rule that governs secret
handling excluded every file where secret handling happens.

This is not unique. An audit of all 79 rules found the same shape elsewhere —
see `.claude/rules/rule-scoping-guard.md` and the bidirectional checker in
`.claude/scripts/check_rule_scoping.sh`. (This paragraph originally cited a
`rule-loading-integrity.md` that was never created — the doc that actually
landed is `rule-scoping-guard.md`; corrected during the llm#943/#944
follow-up, 2026-08-21.)

## 5. Why prose controls were structurally insufficient

The failure did not occur because the rule was unknown, badly worded, or
disagreed with. It was correct and precise. It was **not loaded**, and even
when loaded it is advisory — it depends on the model choosing to recall and
apply it at the moment of action.

The corrective controls are therefore deterministic and run outside the model:

| Control | Type | Blocks |
|---|---|---|
| `.claude/hooks/secret_leak_guard.sh` | `PreToolUse:Bash`, exit 2 | Command substitution in a `gh --body`; secret-named variables passed to `echo`/`printf`; environment dumps into a publish path; literal credential shapes in argv |
| `.claude/scripts/check_rule_scoping.sh` | CI / session check | A rule declared mandatory that is scoped, or absent, or a non-mandatory rule that is unscoped |

`gh_comment_provenance.sh` already existed on the `gh` path but is wired
`PostToolUse` — it observes after execution and could not have prevented this.

## 6. Actions

- [x] Blast radius established by query, not estimate
- [x] `secret_leak_guard.sh` PreToolUse guard
- [x] `check_rule_scoping.sh` made bidirectional; mandatory-rule defects fixed
- [x] `credential-management.md` re-scoped to cover shell/config/dotfile paths
- [x] Follow-up (llm#943/#944, 2026-08-21): `credential-management`,
      `external-code-zero-trust`, `permission-discipline`, and
      `destructive-ops-guard` moved to a new safety-critical tier (AGENTS.md
      "Safety-critical rules" line) and now carry no `paths:` at all — the
      widened-but-still-scoped fix above was a first step, not the final
      state. `check_rule_scoping.sh` enforces the tier (exit 3, blocks
      commits touching rule files) and the pre-commit/session-init wiring
      from llm#952 was confirmed already landed.
- [ ] **User action:** delete the offending comment (assistant cannot — tokens revoked, and `destructive_api_guard` blocks `gh api -X DELETE`)
- [ ] Rotate all 14 credentials — see `.claude/incidents/2026-08-11-rotation-runbook.md`
- [ ] Regenerate `GH_TOKEN` / `GITHUB_PAT` to unblock `gh`
- [ ] File the tracking issues queued in `.claude/incidents/queued-issues/` (Issues 1 and 2 already filed as llm#943 and llm#944)

## 7. Lessons

**A message body passed to Bash is code, not text.** Any prose string handed to
a shell is evaluated before transmission. `--body-file` is the only safe form.

**A near-miss that is repaired rather than explained is a warning discarded.**
The `KeepAlive` mangling and the credential dump were the same bug. Fixing the
symptom of the first guaranteed the second.

**A safety rule that is path-scoped is off by default.** Scoping is a
context-cost optimisation. Applying it to safety-critical content trades a
certainty of protection for a saving of a few hundred tokens.

**Advisory controls degrade silently; deterministic controls fail loudly.**
Prefer the hook.
