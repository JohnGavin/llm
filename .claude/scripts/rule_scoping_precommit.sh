#!/usr/bin/env bash
# rule_scoping_precommit.sh — pre-commit entry point wiring check_rule_scoping.sh
# into `git commit` (llm#952).
#
# WHY THIS EXISTS: check_rule_scoping.sh already catches rule-loading defects
# (a rule declared mandatory in CLAUDE.md/AGENTS.md that silently doesn't
# load) but nothing ran it automatically. Four rules drifted silently this
# way and two were violated during incident response before anyone noticed —
# found by hand, days later. A check nobody runs is the same failure mode as
# a rule nobody reads.
#
# EXIT-CODE CONTRACT (mirrors check_rule_scoping.sh's own contract):
#   checker rc 0   clean               -> silent,          allow commit
#   checker rc 1   context bloat only  -> WARN to stderr,   allow commit
#   checker rc 2   bad rules dir       -> WARN to stderr,   allow commit
#   checker rc 3   mandatory rule not  -> BLOCK,            exit 1
#                  actually loading
# A second pass runs `check_rule_scoping.sh --budget --only <repo>` (check E,
# the always-loaded instruction budget vs Claude Code's startup limit):
#   budget rc 0 / 1 / 3 / other   -> silent / WARN / WARN / WARN, allow
#   budget rc 4 (over the LIMIT)  -> BLOCK only if the staged commit also GROWS
#                                    the instruction files (net chars > 0);
#                                    a trimming commit is allowed with a WARN
# Only rc 3 (and budget rc 4 + growth) blocks. rc 1 (context-bloat direction) is noisy by design —
# see check_rule_scoping.sh's own header. A hook that blocks on noise gets
# `--no-verify`d or deleted within a day; better to WARN and stay trusted.
#
# NOT installed into .git/hooks by this script. Wire it from a pre-commit
# hook with:
#   .claude/scripts/rule_scoping_precommit.sh || exit 1
#
# Fires ONLY when the commit actually touches `.claude/rules/**`,
# `AGENTS.md`, or a `CLAUDE.md` — running the full audit on every commit
# (docs, R code, anything unrelated) is wasted time for no signal.
#
# Kill switch: SKIP_RULE_SCOPING=1 bypasses (logged, never silent — see
# `hook_event_emit.sh`). Every guard in this repo has an escape hatch; a
# guard with none gets removed rather than bypassed.
#
# Fail-open: any internal error (checker missing/unreadable, repo root
# unresolvable) WARNs and allows the commit. Never block a commit because
# the guard itself is broken.
#
# Usage:
#   rule_scoping_precommit.sh            # normal invocation (from a git hook)
#   rule_scoping_precommit.sh --selftest
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_NAME="rule_scoping_precommit"

_emit() { # <event_type> [preview]
  local emitter="$SCRIPT_DIR/hook_event_emit.sh"
  [ -x "$emitter" ] && "$emitter" "$HOOK_NAME" "$1" "${2:-}" >/dev/null 2>&1
  return 0
}

_touches_rule_files() { # <repo_root>
  git -C "$1" diff --cached --name-only 2>/dev/null \
    | grep -qE '(^|/)\.claude/rules/|(^|/)AGENTS\.md$|(^|/)CLAUDE\.md$'
}

# Net change, in chars, of the staged instruction-bearing files (rules,
# AGENTS.md, CLAUDE.md) versus HEAD. Positive = the commit makes the
# always-loaded budget bigger (scoped rules are counted too: a deliberate
# over-approximation, the gate only ever acts when the project is ALREADY
# over the limit). A deleted/new file counts as 0 on its missing side.
_instruction_growth() { # <repo_root>
  local root="$1" f new old total=0
  while IFS= read -r f; do
    case "$f" in
      .claude/rules/*|*/.claude/rules/*|AGENTS.md|*/AGENTS.md|CLAUDE.md|*/CLAUDE.md) ;;
      *) continue ;;
    esac
    new="$(git -C "$root" cat-file -s ":$f" 2>/dev/null)" || new=0
    old="$(git -C "$root" cat-file -s "HEAD:$f" 2>/dev/null)" || old=0
    total=$((total + new - old))
  done < <(git -C "$root" diff --cached --name-only 2>/dev/null)
  echo "$total"
}

# Always-loaded instruction budget gate (check E of check_rule_scoping.sh).
# Blocks ONLY when this repo's session is over the LIMIT *and* the commit
# grows the instruction files — so a trimming commit on an already-over
# project is never blocked, and an unrelated project's overrun never blocks
# this repo (`--only` scopes the verdict to this checkout). WARN-level and
# indeterminate results never block (fail-open, per this script's contract).
_budget_gate() { # <repo_root> <checker>
  local root="$1" checker="$2" bout brc growth lines
  bout="$("$checker" --budget --only "$root" 2>&1)"
  brc=$?
  lines="$(printf '%s\n' "$bout" | grep -E 'RULE-BUDGET-(OVER|WARN|INDETERMINATE)' || true)"
  case "$brc" in
    0) return 0 ;;
    4)
      growth="$(_instruction_growth "$root")"
      if [ "$growth" -gt 0 ]; then
        echo "rule-scoping-precommit: BLOCKED — always-loaded instructions exceed the startup limit and this commit grows them by $growth chars:" >&2
        echo "$lines" >&2
        echo "Trim an always-loaded rule/CLAUDE.md (or add paths: frontmatter), or bypass once with:" >&2
        echo "  SKIP_RULE_SCOPING=1 git commit ..." >&2
        _emit "blocked" "$lines"
        return 1
      fi
      echo "rule-scoping-precommit: WARN — always-loaded instructions are over the startup limit, but this commit does not grow them — allowed:" >&2
      echo "$lines" >&2
      _emit "warned" "$lines"
      return 0
      ;;
    1)
      echo "rule-scoping-precommit: WARN — always-loaded instructions are over the startup WARN threshold (non-blocking):" >&2
      echo "$lines" >&2
      _emit "warned" "$lines"
      return 0
      ;;
    *)
      echo "rule-scoping-precommit: WARN — budget check exit $brc (indeterminate/other), non-blocking:" >&2
      echo "$bout" >&2
      _emit "warned" "$bout"
      return 0
      ;;
  esac
}

# Broken relative markdown links between rule files (check_rule_links.sh).
# WARN-only, never blocks: a dead cross-reference is a documentation defect,
# not a safety-direction problem (see rule-scoping-guard § Only the Safety
# Direction Blocks). A missing/unrunnable link checker is silently skipped.
_links_warn() { # <repo_root>
  local root="$1" lchecker lout lrc
  lchecker="$root/.claude/scripts/check_rule_links.sh"
  [ -x "$lchecker" ] || return 0
  lout="$("$lchecker" "$root/.claude/rules" 2>&1)"
  lrc=$?
  case "$lrc" in
    0) ;;
    *)
      echo "rule-scoping-precommit: WARN — rule link check (exit $lrc), non-blocking:" >&2
      echo "$lout" >&2
      _emit "warned" "rule links: $lout"
      ;;
  esac
  return 0
}

_run() {
  local repo_root checker rc out

  if [ "${SKIP_RULE_SCOPING:-0}" = "1" ]; then
    echo "rule-scoping-precommit: SKIP_RULE_SCOPING=1 — bypassed" >&2
    _emit "bypassed" "SKIP_RULE_SCOPING=1"
    return 0
  fi

  repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || repo_root=""
  if [ -z "$repo_root" ]; then
    echo "rule-scoping-precommit: WARN — could not resolve repo root, skipping (fail-open)" >&2
    _emit "warned" "repo root unresolvable"
    return 0
  fi

  _touches_rule_files "$repo_root" || return 0

  checker="$repo_root/.claude/scripts/check_rule_scoping.sh"
  if [ ! -x "$checker" ]; then
    echo "rule-scoping-precommit: WARN — checker not found/executable at $checker, skipping (fail-open)" >&2
    _emit "warned" "checker missing: $checker"
    return 0
  fi

  out="$("$checker" "$repo_root/.claude/rules" 2>&1)"
  rc=$?

  case "$rc" in
    0)
      _emit "clean" "$out"
      ;;
    3)
      echo "rule-scoping-precommit: BLOCKED — a rule declared mandatory is not loading unconditionally:" >&2
      echo "$out" >&2
      echo "Fix the rule (or the CLAUDE.md/AGENTS.md mandatory-rules line), or bypass once with:" >&2
      echo "  SKIP_RULE_SCOPING=1 git commit ..." >&2
      _emit "blocked" "$out"
      return 1
      ;;
    *)
      echo "rule-scoping-precommit: WARN (checker exit $rc) — non-blocking:" >&2
      echo "$out" >&2
      _emit "warned" "$out"
      ;;
  esac

  _links_warn "$repo_root"
  _budget_gate "$repo_root" "$checker"
}

# ═══════════════════════════════════════════════════════════════════════════
# SELF-TEST MODE
# ═══════════════════════════════════════════════════════════════════════════
if [ "${1:-}" = "--selftest" ]; then
  PASS=0; TOTAL=0
  _ok()   { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); printf '  PASS  %s\n' "$1"; }
  _fail() { TOTAL=$((TOTAL+1)); printf '  FAIL  %s\n' "$1"; }

  TMP="$(mktemp -d /tmp/rule_scoping_precommit_selftest_XXXXXX)"
  trap 'rm -rf "$TMP"' EXIT

  mk_repo() { # <repo-dir>
    mkdir -p "$1/.claude/scripts" "$1/.claude/rules"
    git -C "$1" init -q
    git -C "$1" config user.email test@example.com
    git -C "$1" config user.name test
    printf 'placeholder\n' > "$1/README.md"
    git -C "$1" add README.md
    git -C "$1" commit -q -m init
  }

  mk_fake_checker() { # <repo-dir> <rc> <output>
    printf '#!/usr/bin/env bash\nprintf %%s "%s"\nexit %s\n' "$3" "$2" \
      > "$1/.claude/scripts/check_rule_scoping.sh"
    chmod +x "$1/.claude/scripts/check_rule_scoping.sh"
  }

  stage_rule_change() { # <repo-dir>
    printf '# rule\nbody\n' > "$1/.claude/rules/foo.md"
    git -C "$1" add .claude/rules/foo.md
  }

  stage_unrelated_change() { # <repo-dir>
    printf 'more\n' >> "$1/README.md"
    git -C "$1" add README.md
  }

  # ── Case 1: checker exit 3 blocks ───────────────────────────────────────
  r1="$TMP/repo1"
  mk_repo "$r1"
  mk_fake_checker "$r1" 3 "MANDATORY-BUT-ABSENT: foo"
  stage_rule_change "$r1"
  spool1="$TMP/spool1.jsonl"
  ( cd "$r1" && SKIP_RULE_SCOPING=0 HOOK_EVENTS_SPOOL="$spool1" _run ) >/dev/null 2>&1
  rc1=$?
  [ "$rc1" -eq 1 ] && _ok "checker exit 3 -> precommit blocks (rc=1)" \
    || _fail "checker exit 3 -> precommit blocks (got rc=$rc1)"
  grep -q '"event_type":"blocked"' "$spool1" 2>/dev/null \
    && _ok "checker exit 3 -> telemetry event_type=blocked" \
    || _fail "checker exit 3 -> telemetry event_type=blocked"

  # ── Case 2: checker exit 1 warns and allows ─────────────────────────────
  r2="$TMP/repo2"
  mk_repo "$r2"
  mk_fake_checker "$r2" 1 "UNSCOPED: bar.md"
  stage_rule_change "$r2"
  spool2="$TMP/spool2.jsonl"
  ( cd "$r2" && SKIP_RULE_SCOPING=0 HOOK_EVENTS_SPOOL="$spool2" _run ) >/dev/null 2>&1
  rc2=$?
  [ "$rc2" -eq 0 ] && _ok "checker exit 1 -> precommit allows (rc=0)" \
    || _fail "checker exit 1 -> precommit allows (got rc=$rc2)"
  grep -q '"event_type":"warned"' "$spool2" 2>/dev/null \
    && _ok "checker exit 1 -> telemetry event_type=warned" \
    || _fail "checker exit 1 -> telemetry event_type=warned"

  # ── Case 3: checker exit 0 is silent and allows ─────────────────────────
  r3="$TMP/repo3"
  mk_repo "$r3"
  mk_fake_checker "$r3" 0 "rule-scoping: OK"
  stage_rule_change "$r3"
  spool3="$TMP/spool3.jsonl"
  out3="$( ( cd "$r3" && SKIP_RULE_SCOPING=0 HOOK_EVENTS_SPOOL="$spool3" _run ) 2>&1 )"
  rc3=$?
  [ "$rc3" -eq 0 ] && _ok "checker exit 0 -> precommit allows (rc=0)" \
    || _fail "checker exit 0 -> precommit allows (got rc=$rc3)"
  [ -z "$out3" ] && _ok "checker exit 0 -> no stderr/stdout noise" \
    || _fail "checker exit 0 -> no stderr/stdout noise (got: $out3)"
  grep -q '"event_type":"clean"' "$spool3" 2>/dev/null \
    && _ok "checker exit 0 -> telemetry event_type=clean (emitted even when clean)" \
    || _fail "checker exit 0 -> telemetry event_type=clean (emitted even when clean)"

  # ── Case 4: commit touching no rule files skips entirely ────────────────
  r4="$TMP/repo4"
  mk_repo "$r4"
  mk_fake_checker "$r4" 3 "MANDATORY-BUT-ABSENT: should-never-run"
  stage_unrelated_change "$r4"
  spool4="$TMP/spool4.jsonl"
  ( cd "$r4" && SKIP_RULE_SCOPING=0 HOOK_EVENTS_SPOOL="$spool4" _run ) >/dev/null 2>&1
  rc4=$?
  [ "$rc4" -eq 0 ] && _ok "no rule files staged -> precommit allows without invoking checker" \
    || _fail "no rule files staged -> precommit allows without invoking checker (got rc=$rc4)"
  [ ! -f "$spool4" ] && _ok "no rule files staged -> no telemetry emitted (checker never ran)" \
    || _fail "no rule files staged -> no telemetry emitted (spool exists: $spool4)"

  # ── Case 5: kill switch bypasses and logs ───────────────────────────────
  r5="$TMP/repo5"
  mk_repo "$r5"
  mk_fake_checker "$r5" 3 "MANDATORY-BUT-ABSENT: should-never-run"
  stage_rule_change "$r5"
  spool5="$TMP/spool5.jsonl"
  ( cd "$r5" && SKIP_RULE_SCOPING=1 HOOK_EVENTS_SPOOL="$spool5" _run ) >/dev/null 2>&1
  rc5=$?
  [ "$rc5" -eq 0 ] && _ok "SKIP_RULE_SCOPING=1 -> precommit allows" \
    || _fail "SKIP_RULE_SCOPING=1 -> precommit allows (got rc=$rc5)"
  grep -q '"event_type":"bypassed"' "$spool5" 2>/dev/null \
    && _ok "SKIP_RULE_SCOPING=1 -> telemetry event_type=bypassed (never silent)" \
    || _fail "SKIP_RULE_SCOPING=1 -> telemetry event_type=bypassed (never silent)"

  # ── Case 6: missing checker fails open ───────────────────────────────────
  r6="$TMP/repo6"
  mk_repo "$r6"
  # deliberately do NOT create .claude/scripts/check_rule_scoping.sh
  stage_rule_change "$r6"
  spool6="$TMP/spool6.jsonl"
  ( cd "$r6" && SKIP_RULE_SCOPING=0 HOOK_EVENTS_SPOOL="$spool6" _run ) >/dev/null 2>&1
  rc6=$?
  [ "$rc6" -eq 0 ] && _ok "missing checker -> fail-open, precommit allows" \
    || _fail "missing checker -> fail-open, precommit allows (got rc=$rc6)"
  grep -q '"event_type":"warned"' "$spool6" 2>/dev/null \
    && _ok "missing checker -> telemetry event_type=warned" \
    || _fail "missing checker -> telemetry event_type=warned"

  # ── Budget gate (check E) ────────────────────────────────────────────────
  mk_budget_checker() { # <repo-dir> <budget_rc> — main checks clean (rc 0); --budget exits <budget_rc>
    printf '#!/usr/bin/env bash\nif [ "${1:-}" = "--budget" ]; then echo "RULE-BUDGET-OVER: fake 999999 chars"; exit %s; fi\nexit 0\n' "$2" \
      > "$1/.claude/scripts/check_rule_scoping.sh"
    chmod +x "$1/.claude/scripts/check_rule_scoping.sh"
  }

  # Case 7: budget rc 4 + growth -> BLOCK
  r7="$TMP/repo7"
  mk_repo "$r7"
  mk_budget_checker "$r7" 4
  stage_rule_change "$r7"
  spool7="$TMP/spool7.jsonl"
  ( cd "$r7" && SKIP_RULE_SCOPING=0 HOOK_EVENTS_SPOOL="$spool7" _run ) >/dev/null 2>&1
  rc7=$?
  [ "$rc7" -eq 1 ] && _ok "budget over LIMIT + commit grows rules -> precommit blocks (rc=1)" \
    || _fail "budget over LIMIT + commit grows rules -> precommit blocks (got rc=$rc7)"
  grep -q '"event_type":"blocked"' "$spool7" 2>/dev/null \
    && _ok "budget block -> telemetry event_type=blocked" \
    || _fail "budget block -> telemetry event_type=blocked"

  # Case 8: budget rc 4 but the commit SHRINKS the rule -> allowed with WARN
  r8="$TMP/repo8"
  mk_repo "$r8"
  mk_budget_checker "$r8" 4
  printf '# rule\nbody body body body body body\n' > "$r8/.claude/rules/foo.md"
  git -C "$r8" add .claude/rules/foo.md .claude/scripts/check_rule_scoping.sh
  git -C "$r8" commit -q -m seed
  printf '# rule\n' > "$r8/.claude/rules/foo.md"
  git -C "$r8" add .claude/rules/foo.md
  spool8="$TMP/spool8.jsonl"
  ( cd "$r8" && SKIP_RULE_SCOPING=0 HOOK_EVENTS_SPOOL="$spool8" _run ) >/dev/null 2>&1
  rc8=$?
  [ "$rc8" -eq 0 ] && _ok "budget over LIMIT but commit trims -> precommit allows (rc=0)" \
    || _fail "budget over LIMIT but commit trims -> precommit allows (got rc=$rc8)"
  grep -q '"event_type":"warned"' "$spool8" 2>/dev/null \
    && _ok "budget over LIMIT + trimming commit -> telemetry event_type=warned" \
    || _fail "budget over LIMIT + trimming commit -> telemetry event_type=warned"

  # Case 9: budget rc 1 (WARN only) never blocks, even when growing
  r9="$TMP/repo9"
  mk_repo "$r9"
  mk_budget_checker "$r9" 1
  stage_rule_change "$r9"
  ( cd "$r9" && SKIP_RULE_SCOPING=0 HOOK_EVENTS_SPOOL="$TMP/spool9.jsonl" _run ) >/dev/null 2>&1
  rc9=$?
  [ "$rc9" -eq 0 ] && _ok "budget WARN-level -> precommit allows even when growing" \
    || _fail "budget WARN-level -> precommit allows even when growing (got rc=$rc9)"

  # Case 10: budget rc 3 (indeterminate) fails open
  r10="$TMP/repo10"
  mk_repo "$r10"
  mk_budget_checker "$r10" 3
  stage_rule_change "$r10"
  ( cd "$r10" && SKIP_RULE_SCOPING=0 HOOK_EVENTS_SPOOL="$TMP/spool10.jsonl" _run ) >/dev/null 2>&1
  rc10=$?
  [ "$rc10" -eq 0 ] && _ok "budget indeterminate (rc 3) -> fail-open, precommit allows" \
    || _fail "budget indeterminate (rc 3) -> fail-open, precommit allows (got rc=$rc10)"

  # Case 11: kill switch also bypasses the budget gate
  ( cd "$r7" && SKIP_RULE_SCOPING=1 HOOK_EVENTS_SPOOL="$TMP/spool11.jsonl" _run ) >/dev/null 2>&1
  rc11=$?
  [ "$rc11" -eq 0 ] && _ok "SKIP_RULE_SCOPING=1 bypasses the budget block too" \
    || _fail "SKIP_RULE_SCOPING=1 bypasses the budget block too (got rc=$rc11)"

  # Case 12: broken rule link -> WARN (stderr + telemetry), never blocks
  r12="$TMP/repo12"
  mk_repo "$r12"
  mk_fake_checker "$r12" 0 "rule-scoping: OK"
  printf '#!/usr/bin/env bash\necho "BROKEN-LINK fake"\nexit 1\n' \
    > "$r12/.claude/scripts/check_rule_links.sh"
  chmod +x "$r12/.claude/scripts/check_rule_links.sh"
  stage_rule_change "$r12"
  spool12="$TMP/spool12.jsonl"
  out12="$( ( cd "$r12" && SKIP_RULE_SCOPING=0 HOOK_EVENTS_SPOOL="$spool12" _run ) 2>&1 )"
  rc12=$?
  [ "$rc12" -eq 0 ] && _ok "broken rule link -> precommit allows (WARN-only, rc=0)" \
    || _fail "broken rule link -> precommit allows (got rc=$rc12)"
  case "$out12" in *"rule link check"*) _ok "broken rule link -> WARN printed" ;; *) _fail "broken rule link -> WARN printed (got: $out12)" ;; esac
  grep -q '"event_type":"warned"' "$spool12" 2>/dev/null \
    && _ok "broken rule link -> telemetry event_type=warned" \
    || _fail "broken rule link -> telemetry event_type=warned"

  echo ""
  echo "selftest: ${PASS}/${TOTAL} PASS"
  [ "$PASS" -eq "$TOTAL" ] && exit 0
  exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════
# NORMAL OPERATION
# ═══════════════════════════════════════════════════════════════════════════
_run
exit $?
