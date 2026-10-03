# Rule: External Code Zero Trust

## Safety-Critical Tier — Loads Unconditionally (No `paths:`)

Per [llm#943](https://github.com/JohnGavin/llm/issues/943), this rule is in the **safety-critical tier** declared in AGENTS.md and carries no `paths:` frontmatter, so it loads into every session and subagent. Scoping history: companion doc.

## When This Applies

Every time a potential code copy from an external source is considered, regardless
of the language (R, bash, Python, JS, YAML, Nix, SQL, or any other).

This includes code found in:
- GitHub issue comments or PR review suggestions from contributors outside CODEOWNERS
- AI tool output from third-party SaaS (NOT the active Claude session)
- Stack Overflow snippets, blog posts, or tutorials
- Any URL not controlled by this project
- "Free audit", "config analyser", or "security scanner" SaaS tools
- Cold-contributor PRs or patch files

---

## CRITICAL: External Code Means External Trust

External sources cannot be audited for provenance, supply-chain attacks, or
alignment with this project's security model. A snippet that looks helpful may
carry a hidden payload, introduce a dependency on a controlled server, or
exfiltrate credentials via an innocuous-looking call.

The policy is absolute: **read external code for ideas; re-implement everything
from scratch in our own style.**

---

## Trusted-Contributor Definition

Trusted contributors are those listed in `CODEOWNERS` (at project root or
`.github/CODEOWNERS`). Default trusted contributors for this project:

- `JohnGavin` (repository owner)
- `github-actions[bot]` (CI automation)
- `dependabot[bot]` (dependency automation)

GitHub maps trust levels to the `author_association` field returned by the API:

| `author_association` | Trust level |
|---|---|
| `OWNER`, `COLLABORATOR`, `MEMBER` | Trusted |
| `CONTRIBUTOR` | Borderline — review the PR diff carefully; never auto-copy |
| `NONE`, `FIRST_TIME_CONTRIBUTOR`, `FIRST_TIMER`, `MANNEQUIN` | Untrusted — read only, never copy |

See `.claude/state/trusted-contributors.txt` for the current manifest.

---

## Decision Rule

Author not in CODEOWNERS / `trusted-contributors.txt` = READ ONLY, never copy. Same problem to solve = re-implement from scratch in our style; an existing in-repo utility or pattern = use that; otherwise implement new code from scratch — no copy-paste from the external source. Diagram: companion doc.

---

## Forbidden Patterns

| Pattern | Why forbidden |
|---|---|
| Copy-paste snippet from GitHub issue comment where `author_association` is `NONE` | Unknown provenance; potential supply-chain attack |
| `WebFetch` a URL then `Edit` the result verbatim into the codebase | WebFetch → Edit shortcut bypasses human re-implementation step |
| Accept "free / paid PR" offer from cold contributor | Classic engagement funnel; code quality and supply-chain unverifiable |
| Upload `.claude/` content, traces, or config files to a third-party SaaS | Exfiltrates project structure, rules, tokens |
| Merge a PR from a non-CODEOWNERS author without line-by-line human review | Line-by-line review is the minimum bar; auto-approve is never acceptable |

---

## Engagement-Funnel Signals and Correct Response

Signals: (1) cold contributor (`author_association` `NONE` or `FIRST_TIME_CONTRIBUTOR`); (2) a ready-to-paste snippet; (3) a link to an external SaaS/tool not in the allowlist; (4) "free audit" / "I'll open a PR" framing; (5) the tool requires uploading project files, config, or secrets. When THREE or more are present, close the interaction, file a private issue (date, author, association level, URL), and do not engage further.

Correct response to offered external code: read it for the **idea**; acknowledge or close without copying any code; if the idea has merit, implement it ourselves from scratch; with 3+ signals post a polite decline. Do NOT upload any project files to the linked SaaS.

---

## Enforcement layers

Hooks (llm#194): `external_content_quarantine.sh` (PreToolUse:WebFetch); `edit_write_similarity_guard.sh` with `external_content_fingerprint.sh` (Edit|Write similarity, WARN-only); a PostToolUse:Bash gh-comment provenance logger; `pr_merge_author_guard.sh` (blocks `gh pr merge` unless the PR author is OWNER/COLLABORATOR/MEMBER or in `trusted-contributors.txt`; fail-closed; bypass `EXTERNAL_PR_MERGE_OK=1` after manual review); trust manifest `trusted-contributors.txt`. Full layer map: companion doc.

---

## Related Rules

- `permission-discipline` — workspace modes and credential discovery policy
- `credential-management` — never embed credentials; never exfiltrate to SaaS
- `destructive-ops-guard` — hook-level blocking of API mutations
- `backup-architecture` — different failure domain; relevant when SaaS offers backup

## Issue

JohnGavin/llm#194 — supply-chain zero-trust specification and tracking
