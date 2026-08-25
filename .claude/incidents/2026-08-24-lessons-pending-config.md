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

Nine of the fourteen rows below are one defect wearing different clothes:

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
| 1 | Merge gate printed `PASS` while resolving `gh` from `/usr/local/bin/gh`, which does not exist here | A tool resolved from a hardcoded absolute path degrades to "found nothing" | Resolve from `PATH`; exit 2 for "could not run", distinct from 0/1 | **no** — llm#1012 open |
| 2 | GC read a `gh` 401 as "no merged PR exists", retaining ~5 GB of merged worktrees for weeks | `2>/dev/null \|\| true` + emptiness test erases the error/negative distinction | `check_indeterminate_handling.sh` flags the signature; baseline blocks new instances | **partial** — checker merged, pre-commit hook **not installed** |
| 3 | Rotation completion check was `grep -c '^export' secrets.env # expect 13`; the file has no `export` lines, so it returned 0 for a healthy file *and* an empty one | A check whose output does not vary with its subject is not a check | Runbook rewritten to a value-stripping count with the real number | **yes** — llm#1015 |
| 4 | `CACHIX_AUTH_TOKEN` rotated in `secrets.env` only; 4 repos kept serving the revoked value, `tlang` failed nightly 11 days | A credential lives everywhere it was copied to; enumerate stores *before* revoking | Runbook Step 0 enumeration command + per-surface verification table | **yes** — llm#1015 |
| 5 | Hand-written list of affected repos came to 3 and guessed a repo name that does not exist; the command found the 4th (`solwatch`), failing weekly, unnoticed | Curated lists of "the places that use X" are wrong exactly where it matters | Same Step 0 command | **yes** — llm#1015 |
| 6 | Cutoff skipped the very file the fix existed to recover, reporting `scan complete: 1 processed`. BSD `date -j -f '%Y-%m-%d'` fills unspecified fields from *now* | A green suite of synthetic fixtures misses boundary bugs; fixtures sit far from the edge, real data clusters at it | Fixture *on* the boundary; assert the resolved value directly; mutation-check every new assertion | **no** — memory only ([[feedback_fixtures-hide-boundary-drift]]) |
| 7 | `<cachix-token>` stored verbatim in Bitwarden because a documented one-liner carried an unfilled placeholder | A placeholder inside a runnable command is a defect — a shell command is an invitation to paste | `bws_set_secret.sh` refuses placeholder-shaped values; takes the value on hidden stdin | **yes** — llm#1022 |
| 8 | `bws` said `Doesn't contain a decryption key`; read as "the token is malformed" and written up as "re-issue it". The token was fine — it had never reached `bws` | Before attributing a negative result to the subject, confirm the tool could observe the subject | Rule corollary; no mechanical check exists | **no** — prose only |
| 9 | Cache regen deleted `SIGNAL_ACCOUNT` (cache-only, never in BWS) and disabled Signal capture. Summary read `Keys before: 15 / Keys after: 15` | A destructive step must not be reported at the volume of a routine one; a stable count hides an add-plus-delete | Regen refuses removals without `--allow-removals`; `Churn: +N/-N`; drift check in session banner | **yes** — llm#1025 |
| 10 | Re-typed `SIGNAL_ACCOUNT` was one digit wrong. Written, cache regenerated, `OK: written (length 13)`. Nothing errored — a wrong account is not an *invalid* account | Double entry catches a slip, never a misreading: the same typo typed twice is self-consistent | `--verify-against` + ground-truth registry; `SIGNAL_ACCOUNT` checked against signal-cli's `accounts.json` | **pending** — llm#1026 open |
| 11 | Hook-liveness report claimed 21 hooks "never fired", including two that fired that day | Measuring instrumentation and calling it execution | Separate `instrumented` from `fires`; mark block-only guards as on-block | **no** — llm#1017 open |
| 12 | The pre-commit gate built to catch this defect **had this defect**. `~/.claude/scripts` is a symlink into the main checkout, so the checker's self-derived root always resolved there; run from a worktree it scanned main's baselined files, reported clean, and logged `pass` for every commit | Naming a pattern does not confer immunity to it. Installing a gate is not evidence it works — only watching it *refuse* is | `INDETERMINATE_ROOT` pinned by the caller; staged paths passed explicitly; block-direction verified against the live hook | **pending** — llm#1028 |
| 13 | A selftest's fixture repos inherited the ambient **global** `core.hooksPath` and wrote a `pre-commit` into the real shared hooks directory — which would have run the gate in every repo on the machine | A test that reads ambient config can modify shared state. Fixtures must pin every environment input they depend on | Fixtures set `core.hooksPath` locally; assertion checks the fixture path, which is what caught it | **yes** — llm#1028 |
| 14 | A throwaway probe file was committed while testing the gate, then removed with `reset --mixed` | Verification artefacts must be created outside the tree under test, or removed before the commit that proves the point | none — judgement | **no** |

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

## How to use this file

When an item is closed **mechanically**, move it to a `Closed` section with the
PR that closed it and how the mechanism is triggered. When you are tempted to
close one because the lesson is now well documented — don't. That is the failure
mode this file exists to record.

## Related

- [`checks-must-distinguish-unknown`](../rules/checks-must-distinguish-unknown.md) — the shared shape
- [`2026-08-11-rotation-runbook.md`](2026-08-11-rotation-runbook.md) — rows 3–5
- [`2026-08-11-credential-leak.md`](2026-08-11-credential-leak.md) — the precedent for "advisory controls fail"
- Issues: llm#1012, #1013, #1017, #1018, #1019, #1024, #1026
