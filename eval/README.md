# Agent-Behaviour Eval Harness (MVP)

Tracks [llm#816](https://github.com/JohnGavin/llm/issues/816) — a gap
analysis against Appsilon's "Stop vibe-checking your AI agent" (read for
*ideas only*, re-implemented in our own voice per `external-code-zero-trust`,
#194).

**Status: MVP skeleton, Tier-1 only.** This is the first slice of a larger
plan, built to get the machinery working end-to-end with a minimal task set
— the article's own advice — before adding LLM-judge scoring. It is not a
finished product. See "What this MVP does NOT do" below.

## Why this exists

We change the configuration that steers Claude Code — rules, skills, hooks,
prompts — almost every session. Historically we validated those changes by
how the *next live session felt*: exactly the "vibe-checking" the source
article warns against. We have strong tracing (unified-observability-schema,
`housekeeping_runs`, `command_usage`/`skill_usage`, the dispatch audit,
roborev's DB) but no *evaluation* of agent behaviour quality — no labeled
task set, no repeatable runner, no way to catch a quality regression from a
rule/skill/prompt change before it ships.

> Tracing tells you what happened; evaluation tells you if it was good.

## The three-tier plan

| Tier | What it checks | Judge | Status |
|---|---|---|---|
| **Tier 1 — deterministic** | Did the guard fire? Did the delegation happen? Did the hook block the push? | Regex / string match over a fixture — no model call | **This MVP.** `eval/run.R` |
| **Tier 2 — quasi-deterministic** | Binary rubric items too fuzzy for regex (e.g. "did the agent's explanation correctly name the rule it applied?") | Calibrated LLM-as-judge — locked judge model + prompt, hand-graded against 5-10 examples before trusting scores | **Not built.** TODO markers left in `run.R` and task schema (`check_type: llm_judge`) |
| **Tier 3 — fuzzy** | Faithfulness, relevancy, helpfulness of free-form agent output | LLM-as-judge, softer rubric | **Not built. Lower priority** — we are a config/tooling project, not a RAG product, so Tier 3 is deferred indefinitely unless a concrete need appears |

Tier 2 and Tier 3 are **deliberate follow-ups**, not oversights. Building a
15-task golden set with an uncalibrated LLM judge first would repeat the
exact mistake the source article warns about (trusting an unverified judge).
The plan is: get Tier 1 solid and running in CI/regression-gate context,
*then* calibrate a judge for Tier 2 with hand-graded examples.

## What this MVP delivers

- `eval/tasks/*.yaml` — a golden task set (currently 4 tasks) encoding
  expected agent behaviour drawn from our **actual** rules (not
  hypothetical ones): `auto-delegation`, `agent-no-push-to-main`,
  test-driven-development, `pr-shipping-discipline`.
- `eval/fixtures/*` — one "good" (should-pass) fixture per task, used by the
  runner. Some tasks also ship a companion `*_bad.*` fixture for manual
  contrast reading (not scored by `run.R` in this MVP — see below).
- `eval/run.R` — a single-command Tier-1 runner: loads every task, evaluates
  its deterministic `check` against its fixture, writes
  `eval/results/latest.json`, and prints a human-readable summary. No
  network access, no LLM calls.
- `eval/Makefile` — `make -C eval eval` as the one-command entrypoint.

## What this MVP does NOT do

- **No live agent execution.** Tasks are checked against static fixture
  text (a transcript excerpt, a hook-log excerpt, a unified diff) that
  stands in for what a compliant agent run would produce. It does **not**
  drive an actual Claude Code session and capture its real output. Wiring
  this up to real session transcripts (e.g. via the dispatch audit trail
  or roborev's DB) is a natural next step, tracked as follow-up work under
  #816.
- **No LLM-as-judge.** Every check in this MVP is a regex/string match.
  Tasks that would require judgement calls are deliberately left for
  Tier 2.
- **No regression gate wiring.** The issue's "Regression gate" checkbox
  (run the set when rules/skills/hooks/prompt-affecting files change;
  surface deltas in the overnight digest) is not implemented here — this
  MVP is the runner the gate would eventually call.
- **`_bad.*` fixtures are not scored.** Each task's YAML names exactly one
  fixture (the "good" one) that the runner checks. The paired `_bad.*`
  fixture in `eval/fixtures/` is included so a human reviewing the task can
  see, by contrast, what a *failing* run would look like — it documents the
  check's intent. Automatically asserting that the runner correctly *fails*
  on the bad fixture (a test-of-the-tests) is left as follow-up.

## Running it

From the repo root, inside the project nix shell:

```bash
nix-shell /Users/johngavin/docs_gh/llm/default.nix --run "Rscript eval/run.R"
```

or via the Makefile:

```bash
make -C eval eval
```

Output: a per-task PASS/FAIL/ERROR/SKIPPED line to stdout, an aggregate
score, and a full JSON report at `eval/results/latest.json` (gitignored —
regenerated on every run).

## Adding a task

1. Add `eval/tasks/<your-task-id>.yaml` with:

   ```yaml
   id: <unique-id>
   description: >-
     One sentence: what agent behaviour is expected, and why.
   category: <short-tag, e.g. the rule name>
   source_rule: <path to the rule/skill this task encodes, if any>
   check_type: deterministic   # only supported value in this MVP
   fixture: <your-task-id>_good.txt   # relative to eval/fixtures/
   check:
     contains_all:             # every pattern must match >=1 line
       - "regex pattern"
     contains_none:            # no pattern may match any line
       - "regex pattern"
   ```

2. Add `eval/fixtures/<your-task-id>_good.txt` (or `.diff`, whatever suits
   the content) — the fixture text your `check` block evaluates. Matching
   is per-line, case-insensitive, using PCRE syntax (`grepl(..., perl =
   TRUE, ignore.case = TRUE)`).

3. Run `make -C eval eval` and confirm your task appears and passes.

4. (Optional but encouraged) Add a `<your-task-id>_bad.txt` anti-example
   fixture — not wired into the runner, but valuable for anyone reading the
   task later to see what non-compliant behaviour looks like.

No code changes to `run.R` are needed to add a Tier-1 task — dropping a
YAML + fixture pair is sufficient.

## Related

- [llm#816](https://github.com/JohnGavin/llm/issues/816) — this MVP's
  origin issue and full gap analysis.
- [llm#418](https://github.com/JohnGavin/llm/issues/418) — a narrower,
  earlier framing of the same theme scoped to the roborev pipeline; #816's
  issue explicitly asks that the two share one wiki page and one runner
  rather than diverging. The wiki page
  (`knowledge/wiki/agent-evaluation-patterns.md`) is a separate follow-up,
  not part of this MVP.
- [llm#469](https://github.com/JohnGavin/llm/issues/469) —
  `llm-as-judge-verifier` skill idea (Tier 2 input).
- [llm#808](https://github.com/JohnGavin/llm/issues/808) — per-session
  token/cost accounting, a Tier-1 input this MVP does not yet consume.
- `.claude/rules/auto-delegation.md`, `agent-no-push-to-main.md`,
  `pr-shipping-discipline.md`, `test-driven-development` skill — the rules
  this MVP's golden tasks are drawn from.
