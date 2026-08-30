---
description: Cross-project public artifacts (issues, PRs, comments) may only carry an alias and a count for a private/local-only/confidential repo — never its name, paths, or domain detail; enforced by the repo_visibility() registry and its pre-publish guard
paths:
  - ".claude/hooks/private_repo_detail_guard.sh"
  - ".claude/scripts/repo_visibility.sh"
  - ".claude/state/confidential-repos.txt"
---

# Rule: Private-Repo Detail Locality

## Source

[JohnGavin/llm#794](https://github.com/JohnGavin/llm/issues/794). While filing
[#792](https://github.com/JohnGavin/llm/issues/792) (a cross-project
provisional-constants audit) in this repo, the first published revision named
a private, local-only repo (file paths, the kinds of accounts modelled, the
broker) plus two repos `llmtelemetry`'s own `excluded_dashboard_projects()`
classifies as confidential. No figures leaked and it was redacted within
minutes, but the sequence was wrong: the issue was published, *then*
visibility was checked. Redaction after the fact is incomplete — GitHub
retains issue edit history, and subscribers may already have been emailed the
original body.

## When This Applies

Any time a cross-project artifact — an issue, PR, or comment in a public
repo — aggregates detail from more than one repo of possibly differing
sensitivity. This includes audits, dependency reports, telemetry rollups,
session summaries, and any "sweep across projects" report.

## CRITICAL: Detail Stays in the Repo It Describes

A cross-project artifact's visibility is set by where it happens to be filed,
not by the sensitivity of what it aggregates. Nothing in the toolchain
connects "this detail came from repo X" to "repo X is private" unless it is
checked explicitly, every time, before publishing.

| Artifact | May contain | Must NOT contain |
|---|---|---|
| Public cross-project issue/PR/comment | Repo alias (e.g. "private repo A"), tier counts, a generic pattern name, a pointer to in-repo detail | Repo name, file paths, identifiers, symbol names, values, domain specifics |
| In-repo detail (the private repo itself) | Everything | — |

For a private repo the detail lives **in that repo**: its own issue tracker
if it has a remote, or a local tracker (a numbered `issues/NNNN-*.md`
convention) if it does not.

### Alias stability

Aliases MUST be stable across sweeps, so a later audit can be compared to an
earlier one, and MUST NOT be guessable from ordering (do not sort the
inventory so that alias A is always the alphabetically-first private repo —
that reconstructs the mapping from the alias alone).

## The Visibility Registry

`repo_visibility(path_or_name)` — implemented at
[`.claude/scripts/repo_visibility.sh`](../scripts/repo_visibility.sh) —
classifies any repo into exactly one of four buckets, plus a genuine
`unknown` for an unresolved lookup:

| Value | Meaning | Source |
|---|---|---|
| `public` | Confirmed public on GitHub | `gh repo view OWNER/REPO --json visibility` returns `PUBLIC` |
| `private` | Confirmed private on GitHub | `gh repo view` returns `PRIVATE` |
| `local_only` | No git remote at all | Strictly private — never publishable, regardless of content |
| `confidential_by_policy` | Author-declared sensitive, independent of GitHub's own visibility setting | A repo-local `PRIVATE` marker file at the repo root (the same convention the knowledge hub already uses — see `wiki-conventions`), OR a match in this repo's own `.claude/state/confidential-repos.txt` |
| `unknown` | Lookup could not be affirmatively resolved (network error, `gh` unauthenticated, ambiguous/nonexistent repo, non-GitHub remote, timeout) | — |

**Policy: anything not affirmatively resolved as `public` is treated as
private by every caller.** `unknown` is a real, distinguishable value (per
`checks-must-distinguish-unknown`) — a lookup failure must never silently
collapse into "safe to publish". `repo_visibility.sh`'s classification is
per-repo, not per-remote: a technically-public repo on the
confidential-by-policy list is still not publishable.

### llm's own confidential-by-policy list

`.claude/state/confidential-repos.txt` is this repo's OWN list, in the same
format and spirit as `.claude/state/trusted-contributors.txt`
(`external-code-zero-trust`), but a distinct concern (publish-detail
sensitivity, not code-provenance trust). It is deliberately NOT a dependency
on `llmtelemetry::excluded_dashboard_projects()` — that list lives in a
different R package that this repo's bash hooks must not require to be
installed or loadable. If llm ever identifies a repo that is technically
public but should never have its detail published from here, it goes in
this file, not in llmtelemetry's list.

### Cache

Single-repo classification is cached (`REPO_VISIBILITY_CACHE_TTL`, default
300s) so repeated calls in one session are cheap. The candidate list of
non-public repos (used by the pre-publish guard to know what to scan for) is
a SEPARATE, much more expensive enumeration (`REPO_VISIBILITY_CANDIDATES_TTL`,
default 86400s) that is **never rebuilt inline by a hook** — only
`repo_visibility.sh candidates --refresh` rebuilds it. Seed it once; a
`PreToolUse` hook that tried to rebuild a ~100+-repo candidate list on every
`gh issue create` call would blow any reasonable hook timeout.

## The Pre-Publish Guard

[`.claude/hooks/private_repo_detail_guard.sh`](../hooks/private_repo_detail_guard.sh)
is a `PreToolUse:Bash` hook matching `gh issue create|edit|comment` and
`gh pr create|edit|comment`. For each match:

1. Resolves the target repo (an explicit `--repo`/`-R` flag, else the
   invoking directory's git remote).
2. Classifies it via `repo_visibility.sh classify`. If the target is
   `private`, `local_only`, or `confidential_by_policy`, the command is out
   of scope for this guard and is allowed through immediately.
3. Otherwise (target is `public` OR `unknown` — an unresolved lookup must
   not read as "safe to skip the scan") — scans the command text and any
   `--body-file` contents for the name or path of every repo the cached
   candidate list classifies non-public.
4. Blocks (exit 2) on a match, naming the offending term and pointing at
   this rule.

Bypassable via a command-string prefix
(`PRIVATE_DETAIL_GUARD_BYPASS=1 <command>`) for the inevitable false
positive — a candidate repo name under `PRIVATE_DETAIL_MIN_NAME_LEN`
characters (default 6) is deliberately excluded from bare-name scanning to
avoid tripping on ordinary prose (a repo literally named `R` would otherwise
match "an R package" constantly).

This is not a secrets scanner — it targets names, paths, and domain detail of
private repos, which are not secrets and are invisible to every existing
credential-detection tool (`secret_leak_guard.sh`, `artifact_secret_guard.sh`).

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---|---|---|
| Naming a private repo directly in a public cross-project issue | The exact #792 failure mode | Use a stable alias + count; put detail in the repo it describes |
| Sorting the repo inventory before assigning aliases | Alias A is always the alphabetically-first private repo — reconstructs the mapping | Assign aliases independent of any sort order used for display |
| Redacting a leaked repo name after publishing, and considering it resolved | GitHub retains edit history; subscribers may already be emailed | Prevent pre-publish (this guard), not just fix post-publish |
| Adding a new confidential repo to `llmtelemetry::excluded_dashboard_projects()` only | That list is a different package's dashboard-scoping concern, not consulted by this repo's bash hook | Add to `.claude/state/confidential-repos.txt` as well if this repo's publish actions must respect it |
| Treating a `repo_visibility.sh` lookup failure as "probably fine, publish anyway" | Exactly the failure mode `checks-must-distinguish-unknown` exists to prevent | `unknown` triggers the scan, same as `public` |
| A hook or script that rebuilds the candidates list inline on every publish call | Scans every repo under `~/docs_gh` and shells out to `gh repo view` per repo — cannot fit any hook timeout | `candidates` without `--refresh` returns the existing (possibly stale, possibly empty) cache only |

## Non-Goal

This rule and its guard are not a credential scanner. Credential leakage is
covered separately by `secret-leak-prevention` (`secret_leak_guard.sh`,
`artifact_secret_guard.sh`).

## Related

- [`wiki-conventions`](wiki-conventions.md) — the `PRIVATE` marker-file
  convention this rule reuses rather than inventing a second one
- [`external-code-zero-trust`](external-code-zero-trust.md) — the
  `trusted-contributors.txt` precedent for a repo-local, plain-text policy
  list
- [`roborev-exclude-patterns`](roborev-exclude-patterns.md) — structural
  model for this rule (a `.claude/`-scoped enforcement doc paired with a
  concrete script/config artifact)
- [`checks-must-distinguish-unknown`](../CLAUDE.md) — the fail-closed
  `unknown` contract `repo_visibility.sh` implements
- [`public-private-repo-boundary`](public-private-repo-boundary.md) —
  classifies WHICH repos should be private in the first place; this rule
  covers what public artifacts may say ABOUT repos once that classification
  exists
- [JohnGavin/llm#792](https://github.com/JohnGavin/llm/issues/792) — the
  sweep that exposed this failure (worked separately; not edited from here)
- [JohnGavin/llm#794](https://github.com/JohnGavin/llm/issues/794) — this
  rule's origin issue. Item 4 (a retro-check sweep of existing public
  issues/vignettes for private-repo leakage) is explicitly out of scope for
  this rule's implementation PR — any finding from that sweep is itself
  sensitive content that must not be quoted into a public PR body, so it is
  handled directly by the orchestrator, not by an automated agent dispatch.
