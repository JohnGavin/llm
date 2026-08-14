---
description: How the rule-scoping check (check_rule_scoping.sh) is wired into pre-commit and session-init, and its exit-code contract
paths:
  - ".claude/rules/**"
  - ".claude/scripts/check_rule_scoping.sh"
  - ".claude/scripts/rule_scoping_precommit.sh"
  - ".claude/hooks/session_init*"
---

# Rule: Rule-Scoping Guard — Automatic Trigger for check_rule_scoping.sh

## Origin

[llm#952](https://github.com/JohnGavin/llm/issues/952) — `check_rule_scoping.sh`
existed but had no automatic trigger. Four rules declared mandatory in
`AGENTS.md` silently did not load (`verification-before-completion` and
`systematic-debugging` scoped to `R/**`, `btw-timeouts` scoped despite
`paths: ["**"]` intent, `git-no-compound-cd` absent entirely). Two were
violated during incident response before anyone noticed. A check nobody runs
is the same failure mode as a rule nobody reads — this rule documents the
two triggers that close that gap.

## When This Applies

Whenever `.claude/rules/**`, `AGENTS.md`, or a `CLAUDE.md` is edited, and
whenever a session starts in this repo.

## CRITICAL: Only the Safety Direction Blocks

`check_rule_scoping.sh` checks two directions (see its own header for the
full A/B/C breakdown): **context bloat** (a non-mandatory rule missing
`paths:` — noisy, cosmetic) and **safety** (a rule declared mandatory that is
not actually loading unconditionally — a real defect). Only the safety
direction may block a commit. A guard that blocks on noise gets
`--no-verify`'d or deleted within a day; then the safety direction it also
carries is lost along with it.

## Exit-Code Contract

| `check_rule_scoping.sh` exit | Meaning | Pre-commit (`rule_scoping_precommit.sh`) | Session-init (Phase 15e) |
|---|---|---|---|
| 0 | clean | silent, allow | silent |
| 1 | context-bloat only (non-mandatory rule missing `paths:`) | WARN to stderr, allow | not surfaced (left to `/check`) |
| 2 | bad rules dir / tooling failure | WARN to stderr, allow | not surfaced |
| 3 | a MANDATORY rule is not loading unconditionally | **BLOCK, exit 1** | surfaced (`MANDATORY-BUT-*` line) |

## Two Triggers

1. **Pre-commit** (`.claude/scripts/rule_scoping_precommit.sh`) — fires only
   when the commit's staged files touch `.claude/rules/**`, `AGENTS.md`, or a
   `CLAUDE.md` (checked via `git diff --cached --name-only`). Not installed
   into `.git/hooks` by the script itself; a `pre-commit` hook must call it
   explicitly, e.g. `.claude/scripts/rule_scoping_precommit.sh || exit 1`.
2. **Session-init Phase 15e** — advisory backstop. Pre-commit only catches
   drift introduced by a local `git commit` in this checkout; a pulled
   merge, a stash pop, or a direct file edit outside git never fires it.
   Phase 15e re-runs the checker at every session start (5s timeout,
   fail-open, cached-and-refreshed like the other 15x phases) and surfaces
   only exit-3 findings. See `session-init-phases` rule for the full phase
   table.

## Kill Switch

`SKIP_RULE_SCOPING=1 git commit ...` bypasses the pre-commit check. The
bypass is always logged via `hook_event_emit.sh` (`event_type=bypassed`) —
never silent. Every guard in this repo has an escape hatch; a guard with
none gets removed rather than bypassed, so removing the escape hatch would
make the guard less durable, not more strict.

Session-init Phase 15e has its own independent skip:
`CLAUDE_RULE_SCOPING_CHECK=0`.

## Fail-Open

Both triggers fail open on any internal error (checker missing or not
executable, repo root unresolvable): they WARN and allow. Neither trigger
may block a commit or a session because the guard itself is broken.

## Telemetry

`rule_scoping_precommit.sh` emits one `hook_events` row per invocation that
actually reaches the checker, via `hook_event_emit.sh` with
`hook_name=rule_scoping_precommit` and `event_type` in `{clean, warned,
blocked, bypassed}`. **The clean path emits too** — a check that only emits
when it finds something is indistinguishable from a check that stopped
running (the `zero-metric-evidence-or-defect` failure pattern). A commit
that doesn't touch rule files emits nothing at all (the check never ran).

## Selftests

- `check_rule_scoping.sh --selftest` — 11/11, unchanged by this rule; covers
  the checker's own A/B/C logic.
- `rule_scoping_precommit.sh --selftest` — covers the wiring: exit 3 blocks,
  exit 1 warns and allows, exit 0 is silent and allows, a commit touching no
  rule files skips entirely (checker never invoked), the kill switch
  bypasses and logs, and a missing checker fails open. Each case also
  asserts the correct telemetry `event_type` landed in an isolated spool
  (`HOOK_EVENTS_SPOOL` override).

## Forbidden Patterns

| Pattern | Why wrong | Fix |
|---|---|---|
| Blocking a commit on checker exit 1 | Context-bloat noise, not a defect — would get the hook disabled | Only exit 3 blocks |
| Running the full audit on every commit regardless of staged files | Wasted time on unrelated commits (R code, docs, data) | Gate on `git diff --cached --name-only` touching rule-governing paths |
| Treating a missing/broken checker as a block | The guard itself failing should never stop unrelated work | Fail-open: WARN and allow |
| Silent kill switch | Nobody can tell later whether the guard ran | Always emit `bypassed` telemetry |
| Only emitting telemetry on findings | Indistinguishable from "stopped running" | Emit on the clean path too |

## Related

- `.claude/scripts/check_rule_scoping.sh` — the checker itself; its own header documents the A/B/C check taxonomy in full
- `.claude/scripts/rule_scoping_precommit.sh` — pre-commit wiring
- [`session-init-phases`](session-init-phases.md) — Phase 15e row + the general phase-table convention (5s timeout, fail-open, `CLAUDE_*_CHECK=0` skip var)
- `.claude/scripts/hook_event_emit.sh` — the telemetry emitter (llm#950)
- [llm#952](https://github.com/JohnGavin/llm/issues/952) — origin issue
- [llm#590](https://github.com/JohnGavin/llm/issues/590) — origin of the rule-loading `paths:` frontmatter convention that this check audits
