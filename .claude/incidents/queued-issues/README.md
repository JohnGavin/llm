# Queued issue bodies — file these when `gh` auth is restored

The GitHub tokens were revoked as a consequence of the 2026-08-11 leak, so
these could not be filed at the time they were found. Each section below is a
ready-to-file issue body.

File with `gh issue create --title "…" --body-file <section>` — **never**
`--body "…"`, per `secret_leak_guard.sh` Rule 1.

---

## Issue 1 — [P0] Safety-critical rules are path-scoped and therefore off by default

**Labels:** security, config, P0

### Evidence

An audit of all 79 rules in `.claude/rules/` cross-referenced rule content
against `paths:` frontmatter. Rules whose content is credential-, destruction-
or trust-critical, and the paths they actually load for:

| Rule | Secret/destructive keyword hits | `paths:` scope | Does it load where the risk is? |
|---|---|---|---|
| `credential-management` | 33 | `**/.Renviron*`, `.github/**`, `R/**` | **No** — excludes `.claude/scripts/**`, `bin/**`, `**/*.sh`, `~/.zshenv`, `secrets.env`, plists |
| `external-code-zero-trust` | 9 | `**/CODEOWNERS` | **No** — `CODEOWNERS` is edited approximately never, so a rule CLAUDE.md calls "MANDATORY, ALL PROJECTS" is effectively never loaded |
| `permission-discipline` | 22 | `.claude/settings*.json`, `.claude/hooks/**` | **Partial** — does not load when running arbitrary Bash, which is when permission decisions are actually made |
| `destructive-ops-guard` | 16 | `.claude/hooks/**`, `bin/**` | **Partial** — Part 3 (two-key confirmation for `git reset --hard`, force-push) applies to any Bash call, but only loads when editing hooks |

`credential-management`'s exclusion is the direct cause of the 2026-08-11
credential leak — see `.claude/incidents/2026-08-11-credential-leak.md`.

### Root cause

`paths:` scoping is a **context-cost optimisation** (llm#590 — unscoped rules
inflate subagent base context by ~250 tok/KB). It was applied uniformly,
including to safety-critical rules, where the trade is wrong: a few hundred
tokens saved against a guaranteed gap in protection.

### Proposed fix

1. Introduce an explicit **safety-critical** tier that may not be scoped, in
   addition to the existing mandatory tier.
2. Re-scope or unscope the four rules above.
3. Enforce via the bidirectional `check_rule_scoping.sh` (already extended —
   see Issue 2) plus a content heuristic: a rule exceeding N credential/
   destruction keyword hits must be in the safety-critical tier or carry an
   explicit `scoping-justification:` frontmatter field.

---

## Issue 2 — [P0] `check_rule_scoping.sh` checked only one direction; 3 mandatory rules did not load

**Labels:** security, config, P0

### Evidence

`.claude/CLAUDE.md` declares these mandatory ("auto-loaded, safety-critical,
fire on every session"): `verification-before-completion`,
`systematic-debugging`, `btw-timeouts`, `git-no-compound-cd`,
`nix-agent-shell-protocol`, `worktree-location`,
`agent-identity-and-task-scopes`, `human-in-the-loop-decision-points`,
`auto-delegation`.

Reality as of 2026-08-12:

| Rule | Declared | Actual |
|---|---|---|
| `verification-before-completion` | always loads | `paths: ["R/**","tests/**"]` — absent for shell/config work |
| `systematic-debugging` | always loads | `paths: ["R/**","tests/**"]` — same |
| `git-no-compound-cd` | mandatory | **file does not exist** — content consolidated into `bash-safety.md`; the reference is dangling |

`check_rule_scoping.sh` only flagged *non-mandatory rules lacking `paths:`* —
the context-bloat direction. It never checked the safety direction (mandatory
rule that *is* scoped, or that is missing). Worse, its hardcoded `ALLOW` list
held 8 names against CLAUDE.md's 9, so the checker actively *required* three
mandatory rules to be scoped. **The checker and the stated policy contradicted
each other, and the checker won silently.**

Both `verification-before-completion` and `systematic-debugging` were violated
during the 2026-08-11 session, in files neither rule was scoped to.

### Fix

Landed alongside this issue: the checker now derives the mandatory list from
CLAUDE.md rather than duplicating it, adds MANDATORY-BUT-SCOPED and
MANDATORY-BUT-ABSENT checks, and returns distinct exit codes.

### Remaining

Wire the checker into a pre-commit hook and a session-init phase so drift is
caught within one session rather than at the next audit.

---

## Issue 3 — [P1] Three variable names hold one HuggingFace token

`HF_TOKEN`, `HUGGING_FACE_HUB_TOKEN` and `HUGGINGFACE_API_TOKEN` all carry the
same underlying credential. Whichever name a given script happens to read
decides whether it works, and a rotation that updates only one or two leaves
silent breakage. Consolidate to `HF_TOKEN`; make the others reference it or
delete them.

---

## Issue 4 — [P1] Signal launchd plists are unversioned and contain PII

`~/Library/LaunchAgents/com.johngavin.signal-cli-daemon.plist` and its sibling
are not in version control, so a hand-edit (e.g. moving log paths off `/tmp`)
is lost on any machine rebuild and invisible to review.

They cannot be committed as-is: they embed a phone number, and the repository
is public. Options: parameterise the number via `EnvironmentVariables` sourced
from `~/.config/secrets.env`, or commit a `.template` with a placeholder plus
a generator script.

Related: the phone number already appears in committed history elsewhere — a
separate decision is needed on whether to rewrite history.

---

## Issue 5 — [P1] Overnight digest email fails DNS resolution

The 06:30 digest job shows 41 `github.com` resolution failures against 7 SMTP
failures in its log, i.e. the dominant failure is general DNS at job start,
not the mail path. Diagnosis points to a nix environment resolved before the
network is up. Fix per llm#596: use a GC-rooted derivation and add a
resolvable-host wait before the job body.

---

## Issue 6 — [P2] `gh_comment_provenance.sh` is PostToolUse only

The only hook on the `gh` comment path fires *after* the command executes, so
it can observe but never prevent. `secret_leak_guard.sh` now covers the
PreToolUse side; consider whether the provenance hook should also run
pre-execution, or whether its checks should merge into the new guard to avoid
two hooks parsing the same argv on every Bash call.
