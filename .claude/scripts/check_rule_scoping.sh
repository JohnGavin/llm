#!/usr/bin/env bash
# check_rule_scoping.sh — audit .claude/rules/ for rule-loading defects.
#
# Rules WITHOUT a `paths:` frontmatter key load into EVERY session and EVERY
# subagent context. Only the mandatory core may do so. Unscoped rules inflate
# subagent base context — the "Prompt is too long" failures in llm#590.
# Convention: AGENTS.md "Rule loading is enforced via paths: frontmatter".
#
# The mandatory list is a SINGLE source of truth: it is parsed from the
# "**Mandatory rules**" line in the repo's `.claude/CLAUDE.md` (checked
# first) or `AGENTS.md` (checked second — this is where the line actually
# lives in the llm repo, since `~/.claude/CLAUDE.md` is a symlink to
# `AGENTS.md`). A hardcoded duplicate list is guaranteed to drift from that
# policy line — it already had (llm#590 follow-up): three rules declared
# mandatory in AGENTS.md were not actually loading unconditionally, and the
# checker's own hardcoded ALLOW list silently disagreed with AGENTS.md and
# never caught it. Falls back to a hardcoded list ONLY if neither doc file
# can be parsed, with a WARN — the fallback existing at all is itself a
# smell; fix the doc source instead of relying on it.
#
# A second, PARALLEL tier — safety-critical (llm#943) — is parsed the same
# way from a "**Safety-critical rules**" line. It carries the identical
# "must never be scoped" contract as mandatory, but is named separately
# because its content is a specific credential/trust/destructive-ops
# posture rather than a general session discipline; keeping the two lines
# distinct in AGENTS.md keeps each list short and readable rather than
# merging unrelated rules into one giant "mandatory" bucket. Both tiers are
# still ONE source of truth each (one prose line in AGENTS.md, mechanically
# parsed) — this is not a second hand-maintained copy of the mandatory list,
# it is a second, independently-sourced list using the same parsing
# mechanism. The origin incident (2026-08-11 credential leak) happened
# because `credential-management.md`'s `paths:` scope excluded every file
# where secrets are actually handled — see
# `.claude/incidents/2026-08-11-credential-leak.md`.
#
# Four checks, two directions:
#   A. Context-bloat direction: a rule in NEITHER tier with no `paths:`
#      frontmatter loads into every session/subagent unconditionally.
#   B. Safety direction: a MANDATORY or SAFETY-CRITICAL rule that DOES carry
#      `paths:` frontmatter — so despite being declared "always loads" it
#      silently only fires for matching files.
#   C. Safety direction: a MANDATORY or SAFETY-CRITICAL rule name with no
#      corresponding rule file at all — the declared policy names something
#      that doesn't exist.
#   D. Advisory only, never affects exit code: a rule in NEITHER tier whose
#      content is dense with credential/destruction keywords (>= threshold)
#      and that carries no `scoping-justification:` frontmatter field
#      explaining why it is deliberately still scoped. Printed as ADVISORY
#      lines. Intentionally non-blocking — see the `content_heuristic`
#      function's own header for why a hard block here would be premature.
#
# Usage: check_rule_scoping.sh [rules-dir]
#        check_rule_scoping.sh --selftest
#
# Exit codes:
#   0 = clean (check D advisories, if any, do not change this)
#   1 = check-A failures only (context bloat)
#   2 = rules dir not found / usage error
#   3 = check-B and/or check-C failures present (safety — a mandatory or
#       safety-critical rule is not actually loading as declared). Takes
#       priority over 1 when both classes fail on the same run.
set -euo pipefail

# Fallback list, used ONLY when the "**Mandatory rules**" line cannot be
# parsed from .claude/CLAUDE.md or AGENTS.md. Do not rely on this staying in
# sync — that is precisely the drift this script exists to catch.
FALLBACK_ALLOW="bash-safety btw-timeouts nix-agent-shell-protocol worktree-location \
agent-identity-and-task-scopes human-in-the-loop-decision-points \
auto-delegation pivot-signal"

# Fallback list for the safety-critical tier, used ONLY when the
# "**Safety-critical rules**" line cannot be parsed. Same caveat as above.
FALLBACK_SAFETY_CRITICAL="credential-management external-code-zero-trust \
permission-discipline destructive-ops-guard"

# Content-heuristic threshold (check D). Calibrated 2026-08-21 against the
# 79 rule files existing at the time: the three already-hook-enforced
# secret-handling rules (secret-exposure-scanning, secrets-single-source,
# secret-leak-prevention) score 48-71 and carry `scoping-justification:`;
# the highest UNJUSTIFIED non-tier rule at threshold-setting time
# (long-running-process-supervision) scored 14. Set above that gap. Expect
# to retune as new rules are added — this is a starting point, not a law.
CONTENT_HEURISTIC_THRESHOLD=15
CONTENT_HEURISTIC_PATTERN='credential|secret|token|password|api[_ -]?key|rm -rf|force-push|DROP TABLE|delete repo|destroy|irreversible|force_delete|--force'

has_paths() {
    awk '/^---$/{n++; next} n==1 && /^paths:/{found=1} n>=2{exit} END{exit !found}' "$1"
}

# Does the rule file carry a `scoping-justification:` frontmatter key? Used
# by check D as the documented escape hatch: a rule may score above the
# content-heuristic threshold and still legitimately stay scoped, provided
# it says why (e.g. "enforced by a PreToolUse hook, not advisory-dependent").
has_scoping_justification() {
    awk '/^---$/{n++; next} n==1 && /^scoping-justification:/{found=1} n>=2{exit} END{exit !found}' "$1"
}

# Extract the space-separated list of backtick-quoted rule names from the
# first line matching $2 (a grep -m1 pattern, e.g. '\*\*Mandatory rules') in
# $1. Prints nothing (and returns 1) if the file doesn't exist or has no
# such line.
parse_tier_line() {
    local doc="$1" pattern="$2" line names
    [ -f "$doc" ] || return 1
    line="$(grep -m1 "$pattern" "$doc" || true)"
    [ -n "$line" ] || return 1
    names="$(echo "$line" | grep -oE '`[a-zA-Z0-9_-]+`' | tr -d '`' | tr '\n' ' ')"
    [ -n "$names" ] || return 1
    echo "$names"
}

# Resolve the mandatory-rule-name list for a given rules dir: try
# <repo_root>/.claude/CLAUDE.md, then <repo_root>/AGENTS.md, then fall back
# with a WARN to stderr. The mandatory tier is REQUIRED — if no doc source
# can be parsed at all, silently returning an empty list would mean every
# mandatory-rule check is skipped, so the fallback (a stale but non-empty
# snapshot) is safer than nothing.
resolve_mandatory_list() {
    local rules_dir="$1" repo_root doc out
    repo_root="$(cd "$rules_dir" && cd ../.. && pwd)"
    for doc in "$repo_root/.claude/CLAUDE.md" "$repo_root/AGENTS.md"; do
        out="$(parse_tier_line "$doc" '\*\*Mandatory rules' || true)"
        if [ -n "$out" ]; then
            echo "$out"
            return 0
        fi
    done
    echo "WARN: could not parse a **Mandatory rules** line from .claude/CLAUDE.md or AGENTS.md under $repo_root — falling back to hardcoded list (this can drift; fix the doc source)" >&2
    echo "$FALLBACK_ALLOW"
}

# Resolve the safety-critical-rule-name list (llm#943), same doc search
# order as resolve_mandatory_list. UNLIKE the mandatory tier, an absent
# "**Safety-critical rules**" line is a legitimate state — this tier is
# additive/optional (a repo that hasn't adopted the convention yet has none
# of it), so when a doc source EXISTS but simply has no such line, this
# returns an empty list silently, no WARN, no fallback. The hardcoded
# fallback fires only in the more severe case: neither doc source can even
# be found, which mirrors resolve_mandatory_list's own trigger condition.
#
# KNOWN RESIDUAL GAP (found by mutation-testing this exact function while
# landing llm#943, 2026-08-21 — recorded here rather than silently fixed
# because closing it fully would require either coupling the fallback names
# to a fixed file set, which is its own foot-gun, or threading extra state
# through every --selftest fixture; deferred as a documented trade-off, not
# an oversight): if AGENTS.md's "**Safety-critical rules**" line is deleted
# (but the file itself still exists), the 4 tier rules silently fall out of
# checks B/C entirely and are re-evaluated as ordinary rules under check A
# — since they correctly carry no `paths:`, they get flagged UNSCOPED
# (non-blocking, exit 1) rather than SAFETY-CRITICAL-BUT-ABSENT (blocking,
# exit 3). The identical gap exists for the mandatory tier if a single name
# is dropped from the "**Mandatory rules**" line while its file stays
# unscoped (also demotes silently to check A) — mandatory's fallback only
# protects against the WHOLE line vanishing, not one entry disappearing.
# Net effect: the checker still emits *some* signal (UNSCOPED) either way,
# never total silence, but the signal downgrades from blocking to advisory.
resolve_safety_critical_list() {
    local rules_dir="$1" repo_root doc out any_doc_exists=0
    repo_root="$(cd "$rules_dir" && cd ../.. && pwd)"
    for doc in "$repo_root/.claude/CLAUDE.md" "$repo_root/AGENTS.md"; do
        [ -f "$doc" ] || continue
        any_doc_exists=1
        out="$(parse_tier_line "$doc" '\*\*Safety-critical rules' || true)"
        if [ -n "$out" ]; then
            echo "$out"
            return 0
        fi
    done
    if [ "$any_doc_exists" -eq 1 ]; then
        return 0
    fi
    echo "WARN: could not find .claude/CLAUDE.md or AGENTS.md under $repo_root to parse a **Safety-critical rules** line — falling back to hardcoded list (this can drift; fix the doc source)" >&2
    echo "$FALLBACK_SAFETY_CRITICAL"
}

# Check D (advisory ONLY — never contributes to the exit code). A rule
# outside both the mandatory and safety-critical tiers whose content is
# dense with credential/destruction keywords, and that carries no
# `scoping-justification:` frontmatter explaining why it is deliberately
# still scoped. llm#943 item 3 asks for this heuristic to be "enforced";
# it is implemented here as a printed ADVISORY line rather than a blocking
# failure, a deliberate choice: check B/C (the safety direction) is a
# precise, zero-false-positive signal (a named rule either carries `paths:`
# or it doesn't), but a keyword-density threshold is inherently approximate
# — three already-hook-enforced secret-handling rules
# (secret-exposure-scanning, secrets-single-source, secret-leak-prevention)
# score 48-71 on this heuristic while being correctly scoped (their actual
# enforcement is a PreToolUse hook, not the LLM recalling the rule text at
# the right moment). Blocking commits on an approximate signal is exactly
# the failure mode `rule-scoping-guard.md` already warns about for check A:
# "a guard that blocks on noise gets --no-verify'd or deleted within a day".
# Promote to blocking only after this has run long enough to show a
# near-zero false-positive rate.
content_heuristic_check() {
    local f="$1" name="$2" hits
    hits="$(grep -ciE "$CONTENT_HEURISTIC_PATTERN" "$f" 2>/dev/null || true)"
    [ -n "$hits" ] || hits=0
    if [ "$hits" -ge "$CONTENT_HEURISTIC_THRESHOLD" ] && ! has_scoping_justification "$f"; then
        echo "ADVISORY-HIGH-RISK-UNJUSTIFIED: $name ($hits credential/destruction keyword hits) — not in the mandatory/safety-critical tier and carries no scoping-justification: frontmatter field explaining why it is deliberately still scoped (see llm#943 item 3)"
    fi
}

# Runs checks A, B, C, D against $1 (a rules dir). Prints one finding line
# per defect. Returns 0 clean / 1 check-A-only / 3 check-B-or-C-present.
# Check D never changes the return code (see content_heuristic_check above).
audit() {
    local dir="$1" mandatory safety_critical f rel name has_p m s tier
    local fail_a=0 fail_bc=0
    mandatory="$(resolve_mandatory_list "$dir")"
    safety_critical="$(resolve_safety_critical_list "$dir")"

    while IFS= read -r f; do
        rel="${f#"$dir"/}"
        name="$(basename "$f" .md)"
        if has_paths "$f"; then has_p=1; else has_p=0; fi

        tier=""
        case " $mandatory " in
            *" $name "*) tier="MANDATORY" ;;
        esac
        if [ -z "$tier" ]; then
            case " $safety_critical " in
                *" $name "*) tier="SAFETY-CRITICAL" ;;
            esac
        fi

        if [ -n "$tier" ]; then
            if [ "$has_p" -eq 1 ]; then
                echo "$tier-BUT-SCOPED: $name — declared $tier in CLAUDE.md/AGENTS.md but carries paths:, so it only loads for matching files"
                fail_bc=1
            fi
            continue
        fi

        if [ "$has_p" -eq 0 ]; then
            echo "UNSCOPED: $rel ($(wc -c < "$f" | tr -d ' ') bytes) — add paths: frontmatter (see llm#590)"
            fail_a=1
        fi

        content_heuristic_check "$f" "$name"
    # Companion documents are loaded on demand via explicit Read, not auto-injected
    # by paths: matching, so they don't need (and must not carry) paths: frontmatter.
    done < <(find "$dir" -name '*.md' -type f -not -path '*/_companions/*' | sort)

    for m in $mandatory; do
        if [ ! -f "$dir/$m.md" ]; then
            echo "MANDATORY-BUT-ABSENT: $m — declared mandatory in CLAUDE.md/AGENTS.md but no rule file exists"
            fail_bc=1
        fi
    done
    for s in $safety_critical; do
        if [ ! -f "$dir/$s.md" ]; then
            echo "SAFETY-CRITICAL-BUT-ABSENT: $s — declared safety-critical in CLAUDE.md/AGENTS.md but no rule file exists"
            fail_bc=1
        fi
    done

    if [ "$fail_bc" -eq 1 ]; then
        return 3
    elif [ "$fail_a" -eq 1 ]; then
        return 1
    fi
    return 0
}

if [ "${1:-}" = "--selftest" ]; then
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    pass=0
    total=0

    check_eq() { # check_eq <desc> <actual> <expected>
        total=$((total + 1))
        if [ "$2" = "$3" ]; then
            pass=$((pass + 1))
        else
            echo "FAIL: $1 — expected [$3] got [$2]"
        fi
    }

    mk_repo() { # mk_repo <repo-dir> <mandatory-names-space-sep> [safety-critical-names-space-sep]
        mkdir -p "$1/.claude/rules"
        {
            printf -- '**Mandatory rules** (auto-loaded): %s.\n' \
                "$(for n in $2; do printf '`%s`, ' "$n"; done | sed 's/, $//')"
            if [ -n "${3:-}" ]; then
                printf -- '**Safety-critical rules** (auto-loaded): %s.\n' \
                    "$(for n in $3; do printf '`%s`, ' "$n"; done | sed 's/, $//')"
            fi
        } > "$1/.claude/CLAUDE.md"
    }

    # --- Combined repo: one of every case at once ---
    r1="$tmp/repo1"
    mk_repo "$r1" "mand-ok mand-scoped mand-absent"
    printf -- '---\ndescription: x\n---\n# mandatory ok\nbody\n' > "$r1/.claude/rules/mand-ok.md"
    printf -- '---\npaths:\n  - "R/**"\n---\n# mandatory but scoped\nbody\n' > "$r1/.claude/rules/mand-scoped.md"
    printf -- '# unscoped non-mandatory\nbody\n' > "$r1/.claude/rules/nonmand-unscoped.md"
    printf -- '---\npaths:\n  - "R/**"\n---\n# scoped non-mandatory\nbody\n' > "$r1/.claude/rules/nonmand-scoped.md"
    # mand-absent.md deliberately not created

    out1="$(audit "$r1/.claude/rules")" && rc1=0 || rc1=$?
    check_eq "combined: exit 3 (B/C beats A)" "$rc1" "3"
    c="$(printf '%s\n' "$out1" | grep -c 'MANDATORY-BUT-SCOPED: mand-scoped' || true)"
    check_eq "combined: mand-scoped flagged MANDATORY-BUT-SCOPED" "$c" "1"
    c="$(printf '%s\n' "$out1" | grep -c 'MANDATORY-BUT-ABSENT: mand-absent' || true)"
    check_eq "combined: mand-absent flagged MANDATORY-BUT-ABSENT" "$c" "1"
    c="$(printf '%s\n' "$out1" | grep -c 'UNSCOPED: nonmand-unscoped.md' || true)"
    check_eq "combined: nonmand-unscoped flagged UNSCOPED" "$c" "1"
    c="$(printf '%s\n' "$out1" | grep -c 'mand-ok' || true)"
    check_eq "combined: mand-ok (correctly configured) NOT mentioned" "$c" "0"
    c="$(printf '%s\n' "$out1" | grep -c 'nonmand-scoped' || true)"
    check_eq "combined: nonmand-scoped (correctly configured) NOT mentioned" "$c" "0"

    # --- Isolated exit-code cases ---
    r2="$tmp/repo2"  # check-A only -> exit 1
    mk_repo "$r2" "mand-ok"
    printf -- '---\ndescription: x\n---\n# ok\n' > "$r2/.claude/rules/mand-ok.md"
    printf -- '# unscoped\nbody\n' > "$r2/.claude/rules/nonmand-unscoped.md"
    audit "$r2/.claude/rules" >/dev/null && rc2=0 || rc2=$?
    check_eq "check-A-only exit code" "$rc2" "1"

    r3="$tmp/repo3"  # check-B only -> exit 3
    mk_repo "$r3" "mand-ok"
    printf -- '---\npaths:\n  - "R/**"\n---\n# scoped mandatory\n' > "$r3/.claude/rules/mand-ok.md"
    audit "$r3/.claude/rules" >/dev/null && rc3=0 || rc3=$?
    check_eq "check-B-only exit code" "$rc3" "3"

    r4="$tmp/repo4"  # check-C only -> exit 3
    mk_repo "$r4" "mand-missing"
    audit "$r4/.claude/rules" >/dev/null && rc4=0 || rc4=$?
    check_eq "check-C-only exit code" "$rc4" "3"

    r5="$tmp/repo5"  # clean -> exit 0
    mk_repo "$r5" "mand-ok"
    printf -- '---\ndescription: x\n---\n# ok\n' > "$r5/.claude/rules/mand-ok.md"
    printf -- '---\npaths:\n  - "R/**"\n---\n# scoped\n' > "$r5/.claude/rules/nonmand-scoped.md"
    audit "$r5/.claude/rules" >/dev/null && rc5=0 || rc5=$?
    check_eq "clean exit code" "$rc5" "0"

    # --- Fallback path: no CLAUDE.md/AGENTS.md at all ---
    r6="$tmp/repo6"
    mkdir -p "$r6/.claude/rules"
    printf -- '---\ndescription: x\n---\n# bash-safety\n' > "$r6/.claude/rules/bash-safety.md"
    warn="$(resolve_mandatory_list "$r6/.claude/rules" 2>&1 >/dev/null || true)"
    c="$(printf '%s\n' "$warn" | grep -c 'WARN: could not parse' || true)"
    check_eq "fallback prints WARN when no doc source found" "$c" "1"

    # --- Safety-critical tier (llm#943): same B/C contract as mandatory ---
    r7="$tmp/repo7"  # SC-tier rule scoped -> exit 3, SAFETY-CRITICAL-BUT-SCOPED
    mk_repo "$r7" "mand-ok" "sc-scoped"
    printf -- '---\ndescription: x\n---\n# ok\n' > "$r7/.claude/rules/mand-ok.md"
    printf -- '---\npaths:\n  - "R/**"\n---\n# safety-critical but scoped\n' > "$r7/.claude/rules/sc-scoped.md"
    out7="$(audit "$r7/.claude/rules")" && rc7=0 || rc7=$?
    check_eq "SC-tier scoped -> exit 3" "$rc7" "3"
    c="$(printf '%s\n' "$out7" | grep -c 'SAFETY-CRITICAL-BUT-SCOPED: sc-scoped' || true)"
    check_eq "SC-tier scoped flagged SAFETY-CRITICAL-BUT-SCOPED" "$c" "1"

    r8="$tmp/repo8"  # SC-tier rule absent -> exit 3, SAFETY-CRITICAL-BUT-ABSENT
    mk_repo "$r8" "mand-ok" "sc-missing"
    printf -- '---\ndescription: x\n---\n# ok\n' > "$r8/.claude/rules/mand-ok.md"
    out8="$(audit "$r8/.claude/rules")" && rc8=0 || rc8=$?
    check_eq "SC-tier absent -> exit 3" "$rc8" "3"
    c="$(printf '%s\n' "$out8" | grep -c 'SAFETY-CRITICAL-BUT-ABSENT: sc-missing' || true)"
    check_eq "SC-tier absent flagged SAFETY-CRITICAL-BUT-ABSENT" "$c" "1"

    r9="$tmp/repo9"  # SC-tier rule correctly unscoped -> clean, not mentioned
    mk_repo "$r9" "mand-ok" "sc-ok"
    printf -- '---\ndescription: x\n---\n# ok\n' > "$r9/.claude/rules/mand-ok.md"
    printf -- '# safety-critical, correctly unscoped\nbody\n' > "$r9/.claude/rules/sc-ok.md"
    out9="$(audit "$r9/.claude/rules")" && rc9=0 || rc9=$?
    check_eq "SC-tier correctly unscoped -> exit 0" "$rc9" "0"
    c="$(printf '%s\n' "$out9" | grep -c 'sc-ok' || true)"
    check_eq "SC-tier correctly unscoped NOT mentioned" "$c" "0"

    r10="$tmp/repo10"  # doc exists, no SC line -> empty list, no WARN, no false ABSENT
    mk_repo "$r10" "mand-ok"
    printf -- '---\ndescription: x\n---\n# ok\n' > "$r10/.claude/rules/mand-ok.md"
    sc_out="$(resolve_safety_critical_list "$r10/.claude/rules" 2>&1 >/dev/null || true)"
    check_eq "doc exists, no SC line -> resolve_safety_critical_list silent (no WARN)" "$sc_out" ""
    audit "$r10/.claude/rules" >/dev/null && rc10=0 || rc10=$?
    check_eq "doc exists, no SC line -> audit still clean (no phantom ABSENT)" "$rc10" "0"

    r11="$tmp/repo11"  # neither doc exists -> SC fallback WARN fires
    mkdir -p "$r11/.claude/rules"
    printf -- '---\ndescription: x\n---\n# ok\n' > "$r11/.claude/rules/credential-management.md"
    printf -- '---\ndescription: x\n---\n# ok\n' > "$r11/.claude/rules/external-code-zero-trust.md"
    printf -- '---\ndescription: x\n---\n# ok\n' > "$r11/.claude/rules/permission-discipline.md"
    printf -- '---\ndescription: x\n---\n# ok\n' > "$r11/.claude/rules/destructive-ops-guard.md"
    warn_sc="$(resolve_safety_critical_list "$r11/.claude/rules" 2>&1 >/dev/null || true)"
    c="$(printf '%s\n' "$warn_sc" | grep -c 'WARN: could not find' || true)"
    check_eq "neither doc exists -> SC fallback prints WARN" "$c" "1"

    # --- Content heuristic (check D): advisory only, never blocks ---
    r12="$tmp/repo12"
    mk_repo "$r12" "mand-ok"
    printf -- '---\ndescription: x\n---\n# ok\n' > "$r12/.claude/rules/mand-ok.md"
    {
        echo "---"
        echo 'paths:'
        echo '  - "R/**"'
        echo "---"
        echo "# high-risk rule, no justification"
        i=0
        while [ "$i" -lt 16 ]; do
            echo "This line mentions a secret credential token on its own line $i."
            i=$((i + 1))
        done
    } > "$r12/.claude/rules/high-risk-unjustified.md"
    out12="$(audit "$r12/.claude/rules")" && rc12=0 || rc12=$?
    check_eq "content heuristic alone never blocks (exit stays 0)" "$rc12" "0"
    c="$(printf '%s\n' "$out12" | grep -c 'ADVISORY-HIGH-RISK-UNJUSTIFIED: high-risk-unjustified' || true)"
    check_eq "content heuristic flags dense unjustified rule" "$c" "1"

    r13="$tmp/repo13"  # same density, but with scoping-justification -> no advisory
    mk_repo "$r13" "mand-ok"
    printf -- '---\ndescription: x\n---\n# ok\n' > "$r13/.claude/rules/mand-ok.md"
    {
        echo "---"
        echo "scoping-justification: enforced by a PreToolUse hook, not advisory-dependent"
        echo 'paths:'
        echo '  - "R/**"'
        echo "---"
        echo "# high-risk rule, justified"
        i=0
        while [ "$i" -lt 16 ]; do
            echo "This line mentions a secret credential token on its own line $i."
            i=$((i + 1))
        done
    } > "$r13/.claude/rules/high-risk-justified.md"
    out13="$(audit "$r13/.claude/rules")"
    c="$(printf '%s\n' "$out13" | grep -c 'ADVISORY-HIGH-RISK-UNJUSTIFIED: high-risk-justified' || true)"
    check_eq "content heuristic silent when scoping-justification present" "$c" "0"

    echo "selftest: ${pass}/${total} PASS"
    [ "$pass" -eq "$total" ]
    exit
fi

RULES_DIR="${1:-/Users/johngavin/docs_gh/llm/.claude/rules}"
if [ ! -d "$RULES_DIR" ]; then
    echo "check_rule_scoping: rules dir not found: $RULES_DIR" >&2
    exit 2
fi
rc=0
audit "$RULES_DIR" || rc=$?
if [ "$rc" -eq 0 ]; then
    echo "rule-scoping: OK — all non-tier rules carry paths: frontmatter; all mandatory/safety-critical rules load unconditionally"
fi
exit "$rc"
