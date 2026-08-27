# Lessons pending config — opened 2026-08-25

A running ledger. Each row is a failure observed in practice, the durable lesson,
the **mechanical** change that would prevent recurrence, and whether that change
exists yet.

**The point of this file is the `Enforced?` column.** Everything here is already
written down somewhere — in a rule, a memory, a commit message. Writing it down
is what we did last time. The 2026-08-11 credential leak had a rule forbidding
it, an open issue naming the risk, and a self-check that swept for the wrong
pattern; all three were advisory and all three failed. A lesson with `Enforced?
= no` should be read as *not yet learned*.

Close a row only when a hook, gate, or refusal makes the mistake structurally
hard — not when the prose is good.

---

## Naming the pattern does not stop you falling into it

The most useful finding of 2026-08-25 is not in any single row. It is that
**two new instances were produced by code written to prevent the pattern**,
hours after it was codified as a rule and merged:

- Row 8 — `bws` said `Doesn't contain a decryption key`; that was read as "the
  token is malformed" and written up as advice to re-issue a working
  credential. The tool had received nothing.
- Row 12 — the pre-commit gate built to catch this defect shipped *with* this
  defect, scanning the wrong repo and reporting clean.

Both were written by someone who had just finished writing the rule. So the
rule is not a vaccine, and this file should not be read as one either. The only
rows that have ever stopped a recurrence are the ones in the `Enforced?` column
marked **yes** — a refusal, a non-zero exit, a blocked commit.

Corollary, learned the same day: **installing a gate is not evidence it works.**
Row 12 passed a commit it should have blocked, silently, while logging `pass`.
The gate was only proven by deliberately committing the forbidden pattern and
watching it refuse. Every gate added from here should be accompanied by a
recorded observation of it *failing closed*, not merely of it being present.

## The single shape

Nine of the sixteen rows below are one defect wearing different clothes:

> **A system reported success about something it had not established.**

An error path and a negative-result path sharing an exit. "I could not answer"
rendered as "the answer is no", or "I did not check" rendered as "it is fine".

Codified as [`checks-must-distinguish-unknown`](../rules/checks-must-distinguish-unknown.md)
(llm#1021). That rule is prose; `check_indeterminate_handling.sh` (llm#1022,
llm#1025) is the part that fires without anyone remembering.

---

## Ledger

| # | What happened | Lesson | Mechanical prevention | Enforced? |
|---|---|---|---|---|
| 1 | Merge gate printed `PASS` while resolving `gh` from `/usr/local/bin/gh`, which does not exist here | A tool resolved from a hardcoded absolute path degrades to "found nothing" | Resolve from `PATH`; **exit 3** for "could not run", distinct from 0/1; tests assert the output does not contain `PASS` | **yes** — llm#1012 |
| 2 | GC read a `gh` 401 as "no merged PR exists", retaining ~5 GB of merged worktrees for weeks | `2>/dev/null \|\| true` + emptiness test erases the error/negative distinction | `is_squash_merged()` returns 2 for "could not ask"; `squash-detect-failures=N` on the summary; `check_indeterminate_handling.sh` flags the signature | **yes** — llm#1019 fixed the instance; llm#1028 installed the gate. Verified blocking 2026-08-27: a probe commit carrying the signature exits 1 with `Commit BLOCKED: new swallowed-error finding(s)` |
| 3 | Rotation completion check was `grep -c '^export' secrets.env # expect 13`; the file has no `export` lines, so it returned 0 for a healthy file *and* an empty one | A check whose output does not vary with its subject is not a check | Runbook rewritten to a value-stripping count with the real number | **yes** — llm#1015 |
| 4 | `CACHIX_AUTH_TOKEN` rotated in `secrets.env` only; 4 repos kept serving the revoked value, `tlang` failed nightly 11 days | A credential lives everywhere it was copied to; enumerate stores *before* revoking | Runbook Step 0 enumeration command + per-surface verification table | **yes** — llm#1015 |
| 5 | Hand-written list of affected repos came to 3 and guessed a repo name that does not exist; the command found the 4th (`solwatch`), failing weekly, unnoticed | Curated lists of "the places that use X" are wrong exactly where it matters | Same Step 0 command | **yes** — llm#1015 |
| 6 | Cutoff skipped the very file the fix existed to recover, reporting `scan complete: 1 processed`. BSD `date -j -f '%Y-%m-%d'` fills unspecified fields from *now* | A green suite of synthetic fixtures misses boundary bugs; fixtures sit far from the edge, real data clusters at it | Fixture *on* the boundary; assert the resolved value directly; mutation-check every new assertion | **no** — memory only ([[feedback_fixtures-hide-boundary-drift]]) |
| 7 | `<cachix-token>` stored verbatim in Bitwarden because a documented one-liner carried an unfilled placeholder | A placeholder inside a runnable command is a defect — a shell command is an invitation to paste | `bws_set_secret.sh` refuses placeholder-shaped values; takes the value on hidden stdin | **yes** — llm#1022 |
| 8 | `bws` said `Doesn't contain a decryption key`; read as "the token is malformed" and written up as "re-issue it". The token was fine — it had never reached `bws` | Before attributing a negative result to the subject, confirm the tool could observe the subject | Rule corollary; no mechanical check exists | **no** — prose only |
| 9 | Cache regen deleted `SIGNAL_ACCOUNT` (cache-only, never in BWS) and disabled Signal capture. Summary read `Keys before: 15 / Keys after: 15` | A destructive step must not be reported at the volume of a routine one; a stable count hides an add-plus-delete | Regen refuses removals without `--allow-removals`; `Churn: +N/-N`; drift check in session banner | **yes** — llm#1025 |
| 10 | Re-typed `SIGNAL_ACCOUNT` was one digit wrong. Written, cache regenerated, `OK: written (length 13)`. Nothing errored — a wrong account is not an *invalid* account | Double entry catches a slip, never a misreading: the same typo typed twice is self-consistent | `--verify-against` + ground-truth registry; `SIGNAL_ACCOUNT` checked against signal-cli's `accounts.json` | **pending** — llm#1026 open |
| 11 | Hook-liveness report claimed 21 hooks "never fired", including two that fired that day | Measuring instrumentation and calling it execution | `instrumented`/`cadence` read from each hook's own `# hook-liveness:` marker; uninstrumented renders `—`, never `0`; a test fails if an instrumented hook lacks a marker | **yes** — llm#1017 |
| 12 | `secret_leak_guard` recommended a remedy that `compound_command_guard` rejects, and justified itself with a claim about `${VAR:+…}` that is false | A guard whose stated reason can be disproved in ten seconds teaches the reader to work around it; a remedy that another guard blocks leaves the operator improvising under pressure | Message names `test -n "${VAR:-}"`, which passes both guards; rationale corrected; `PAT` matched as a delimited token so PATH/path/wt_path/pattern stop tripping it; 13 selftest cases | **yes** — llm#1018 |
| 13 | A GC log line wrote a live GitHub token in plaintext, because one repo's `remote.origin.url` embeds one and the new diagnostic logged the slug | Anything derived from a remote URL or a tool's stderr is a credential-bearing surface the moment it reaches a log | `redact_credentials()` on every reason string; slug parse strips `user:pass@` before parsing | **partial** — llm#1019 covers `worktree_gc.sh`; the embedded token still needs rotating and the remote still needs fixing, and nothing yet scans *other* scripts for the same shape |
| 14 | The pre-commit gate built to catch this defect **had this defect**. `~/.claude/scripts` is a symlink into the main checkout, so the checker's self-derived root always resolved there; run from a worktree it scanned main's baselined files, reported clean, and logged `pass` for every commit | Naming a pattern does not confer immunity to it. Installing a gate is not evidence it works — only watching it *refuse* is | `INDETERMINATE_ROOT` pinned by the caller; staged paths passed explicitly; block-direction verified against the live hook | **pending** — llm#1028 |
| 15 | A selftest's fixture repos inherited the ambient **global** `core.hooksPath` and wrote a `pre-commit` into the real shared hooks directory — which would have run the gate in every repo on the machine | A test that reads ambient config can modify shared state. Fixtures must pin every environment input they depend on | Fixtures set `core.hooksPath` locally; assertion checks the fixture path, which is what caught it | **yes** — llm#1028 |
| 16 | A throwaway probe file was committed while testing the gate, then removed with `reset --mixed` | Verification artefacts must be created outside the tree under test, or removed before the commit that proves the point | none — judgement | **no** |

---

## Pending config changes

What to change in `AGENTS.md`, `settings.json` or hooks **once the open items
land**. Not applied yet — listed so the eventual edit is a transcription rather
than a recollection.

### 1. Install the pre-commit gate for `check_indeterminate_handling.sh`

`indeterminate_precommit.sh` ships (llm#1025) but `.git/hooks/pre-commit` is not
version-controlled, so it is **not wired in**. One line, mirroring how
`rule_scoping_precommit.sh` is called. Until then row 2 stays `partial` and the
checker catches nothing — which is exactly what "advisory" bought us on
2026-08-24, when it failed to flag two new instances written that same day.

### 2. `AGENTS.md` — a "Checks" clause in Core Rules

Currently the rule is path-scoped, so it loads only when scripts are touched.
The *diagnostic* corollary (row 8) applies to every session, including ones that
touch no code. Candidate wording:

> **Checks and diagnosis:** a check has three outcomes — positive, negative, and
> *indeterminate*. Never let "I could not determine this" exit the same way as a
> negative. Before attributing a negative result to the subject, confirm the tool
> could observe the subject. A tool complaining about the *shape* of an input may
> not have received it.

### 3. Ground-truth registry, once llm#1026 merges

Add to the rotation runbook: *"If the secret has an entry in
`lib/secret_ground_truth.sh`, the write is verified automatically. If it does
not, consider whether the consuming system can be asked."*

### 4. Retire the `GH_TOKEN` workaround

Every `gh` call in this session needed `env -u GH_TOKEN` because a revoked token
shadows the working keyring credential. That is a live trap for hooks and cron,
not just interactive use — and it is one of the ways llm#1012's gate fail-opens.
Once cleared, remove the workaround from any script that carries it.

### 5. Fixture discipline (row 6) — currently memory-only

No mechanism exists. Weakest candidate here, and worth saying so rather than
pretending the memory is enough. Options, in order of cost:

- a `--selftest` convention requiring at least one boundary fixture (advisory)
- a mutation harness (`mutator` is on the review list for exactly this)
- accept it as judgement, and stop claiming it is "handled"

---

### 6. Outstanding after the 2026-08-25 fix pass (llm#1012/#1017/#1018/#1019)

Three things the four fixes deliberately did **not** do:

- **`indeterminate_precommit.sh` is still not wired into `.git/hooks/pre-commit`.**
  Row 2 stays `partial` for this reason. The four instances fixed on
  2026-08-25 were all found and fixed by hand; the checker would not have
  blocked any of them, because it never runs. This is one line, and it is
  the difference between "we fixed four" and "a fifth cannot land".

- **`check_indeterminate_handling.sh` does not catch llm#1012's shape.** Run
  it against `bin/roborev_merge_gate.sh` as it was and it reports
  `findings=0`: the swallow (`2>/dev/null || echo ""`) lived inside a
  function and the emptiness test lived in its caller, one call apart, so
  the pattern-1 matcher never saw them together. The checker written for
  this family misses the issue it names first in its own header.

- **The embedded credential in a `remote.origin.url` is contained, not
  resolved.** The token is out of `worktree_gc.log` and the script now
  redacts, but the token itself is unrotated, the remote still embeds it,
  and no scan looks for the same shape in other scripts that log a remote
  URL.

### Reconciled 2026-08-27 — what is now actually enforced

Items 1, 2, 4 and all three of section 6 above are **done**. Left standing,
they were the failure this file exists to name: a ledger that reports work as
pending after it has shipped is as misleading as one that reports it done
before. Verified, each by running the thing rather than reading it:

| Item | Status | Evidence |
|---|---|---|
| 1 · install the pre-commit gate | **done** | llm#1028 merged; `indeterminate_hook_install.sh --repo ~/docs_gh/llm` run. A probe commit carrying the signature now exits 1 with `Commit BLOCKED: new swallowed-error finding(s)`. The probe cleaned itself up — no repeat of the row-16 artefact |
| 2 · `AGENTS.md` "Checks" clause | **done** | present in `AGENTS.md` |
| 4 · retire the `GH_TOKEN` workaround | **done for new shells** | a clean-env login shell has it unset and `gh api user` succeeds with no workaround. It survives only in already-running processes, which no edit can reach |
| 6a · gate not wired in | **done** | same as item 1 |
| 6b · checker misses llm#1012's shape | **done** | llm#1030 added pattern 3; the pre-fix gate now reports 2 findings naming `_resolve_repo()` and `_get_pr_commits()`, where it previously reported `findings=0` |
| 6c · credential in a remote URL | **contained** | 208 repos scanned, 0 credentialed remotes; `credential_hygiene_check.sh` detects recurrence. The token itself was revoked by GitHub on 2026-08-11 and is not regenerated — deliberately, since `gh` works from the keyring |

Still genuinely open: item 3 (ground-truth registry wording), item 5 (fixture
discipline, memory-only), and the two follow-ups filed 2026-08-26 —
llm#1035 (the roborev report files failed reviews under a "not a backlog"
heading) and llm#1037.

## How to use this file

When an item is closed **mechanically**, move it to a `Closed` section with the
PR that closed it and how the mechanism is triggered. When you are tempted to
close one because the lesson is now well documented — don't. That is the failure
mode this file exists to record.

## Related

- [`checks-must-distinguish-unknown`](../rules/checks-must-distinguish-unknown.md) — the shared shape
- [`2026-08-11-rotation-runbook.md`](2026-08-11-rotation-runbook.md) — rows 3–5
- [`2026-08-11-credential-leak.md`](2026-08-11-credential-leak.md) — the precedent for "advisory controls fail"
- Issues: llm#1012, #1013, #1017, #1018, #1019, #1024, #1026 (#1012, #1017, #1018 closed by fix; #1019 closed by fix, credential rotation outstanding)
