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
# Three checks, two directions:
#   A. Context-bloat direction: a NON-mandatory rule with no `paths:`
#      frontmatter loads into every session/subagent unconditionally.
#   B. Safety direction: a MANDATORY rule that DOES carry `paths:`
#      frontmatter — so despite being declared "always loads" it silently
#      only fires for matching files.
#   C. Safety direction: a MANDATORY rule name with no corresponding rule
#      file at all — the declared policy names something that doesn't exist.
#
# Usage: check_rule_scoping.sh [rules-dir]
#        check_rule_scoping.sh --selftest
#
# Exit codes:
#   0 = clean
#   1 = check-A failures only (context bloat)
#   2 = rules dir not found / usage error
#   3 = check-B and/or check-C failures present (safety — a mandatory rule
#       is not actually loading as declared). Takes priority over 1 when
#       both classes fail on the same run.
set -euo pipefail

# Fallback list, used ONLY when the "**Mandatory rules**" line cannot be
# parsed from .claude/CLAUDE.md or AGENTS.md. Do not rely on this staying in
# sync — that is precisely the drift this script exists to catch.
FALLBACK_ALLOW="bash-safety btw-timeouts nix-agent-shell-protocol worktree-location \
agent-identity-and-task-scopes human-in-the-loop-decision-points \
auto-delegation pivot-signal"

has_paths() {
    awk '/^---$/{n++; next} n==1 && /^paths:/{found=1} n>=2{exit} END{exit !found}' "$1"
}

# Extract the space-separated list of backtick-quoted rule names from the
# first line matching "**Mandatory rules**" in $1. Prints nothing (and
# returns 1) if the file doesn't exist or has no such line.
parse_mandatory_line() {
    local doc="$1" line names
    [ -f "$doc" ] || return 1
    line="$(grep -m1 '\*\*Mandatory rules' "$doc" || true)"
    [ -n "$line" ] || return 1
    names="$(echo "$line" | grep -oE '`[a-zA-Z0-9_-]+`' | tr -d '`' | tr '\n' ' ')"
    [ -n "$names" ] || return 1
    echo "$names"
}

# Resolve the mandatory-rule-name list for a given rules dir: try
# <repo_root>/.claude/CLAUDE.md, then <repo_root>/AGENTS.md, then fall back
# with a WARN to stderr.
resolve_mandatory_list() {
    local rules_dir="$1" repo_root doc out
    repo_root="$(cd "$rules_dir" && cd ../.. && pwd)"
    for doc in "$repo_root/.claude/CLAUDE.md" "$repo_root/AGENTS.md"; do
        out="$(parse_mandatory_line "$doc" || true)"
        if [ -n "$out" ]; then
            echo "$out"
            return 0
        fi
    done
    echo "WARN: could not parse a **Mandatory rules** line from .claude/CLAUDE.md or AGENTS.md under $repo_root — falling back to hardcoded list (this can drift; fix the doc source)" >&2
    echo "$FALLBACK_ALLOW"
}

# Runs checks A, B, C against $1 (a rules dir). Prints one finding line per
# defect. Returns 0 clean / 1 check-A-only / 3 check-B-or-C-present.
audit() {
    local dir="$1" mandatory f rel name has_p m
    local fail_a=0 fail_bc=0
    mandatory="$(resolve_mandatory_list "$dir")"

    while IFS= read -r f; do
        rel="${f#"$dir"/}"
        name="$(basename "$f" .md)"
        if has_paths "$f"; then has_p=1; else has_p=0; fi

        case " $mandatory " in
            *" $name "*)
                if [ "$has_p" -eq 1 ]; then
                    echo "MANDATORY-BUT-SCOPED: $name — declared mandatory in CLAUDE.md/AGENTS.md but carries paths:, so it only loads for matching files"
                    fail_bc=1
                fi
                continue
                ;;
        esac

        if [ "$has_p" -eq 0 ]; then
            echo "UNSCOPED: $rel ($(wc -c < "$f" | tr -d ' ') bytes) — add paths: frontmatter (see llm#590)"
            fail_a=1
        fi
    # Companion documents are loaded on demand via explicit Read, not auto-injected
    # by paths: matching, so they don't need (and must not carry) paths: frontmatter.
    done < <(find "$dir" -name '*.md' -type f -not -path '*/_companions/*' | sort)

    for m in $mandatory; do
        if [ ! -f "$dir/$m.md" ]; then
            echo "MANDATORY-BUT-ABSENT: $m — declared mandatory in CLAUDE.md/AGENTS.md but no rule file exists"
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

    mk_repo() { # mk_repo <repo-dir> <mandatory-names-space-sep>
        mkdir -p "$1/.claude/rules"
        printf -- '**Mandatory rules** (auto-loaded): %s.\n' \
            "$(for n in $2; do printf '`%s`, ' "$n"; done | sed 's/, $//')" \
            > "$1/.claude/CLAUDE.md"
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
    echo "rule-scoping: OK — all non-mandatory rules carry paths: frontmatter; all mandatory rules load unconditionally"
fi
exit "$rc"
