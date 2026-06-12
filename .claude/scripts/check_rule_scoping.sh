#!/usr/bin/env bash
# check_rule_scoping.sh — audit .claude/rules/ for unscoped (always-loaded) rules.
#
# Rules WITHOUT a `paths:` frontmatter key load into EVERY session and EVERY
# subagent context. Only the mandatory core may do so. Unscoped rules inflate
# subagent base context — the "Prompt is too long" failures in llm#590.
# Convention: AGENTS.md "Rule loading is enforced via paths: frontmatter".
#
# Usage: check_rule_scoping.sh [rules-dir]
#        check_rule_scoping.sh --selftest
# Exit 0 = clean; 1 = unscoped non-mandatory rule(s) found.
set -euo pipefail

# Rules allowed to load unconditionally. Keep in sync with the
# "Mandatory rules" line in AGENTS.md (llm#590, PR #613).
ALLOW="bash-safety btw-timeouts nix-agent-shell-protocol worktree-location \
agent-identity-and-task-scopes human-in-the-loop-decision-points \
auto-delegation pivot-signal"

has_paths() {
    awk '/^---$/{n++; next} n==1 && /^paths:/{found=1} n>=2{exit} END{exit !found}' "$1"
}

audit() {
    local dir="$1" fail=0 f rel name
    while IFS= read -r f; do
        rel="${f#"$dir"/}"
        name="$(basename "$f" .md)"
        if has_paths "$f"; then
            continue
        fi
        case " $ALLOW " in
            *" $name "*) continue ;;
        esac
        echo "UNSCOPED: $rel ($(wc -c < "$f" | tr -d ' ') bytes) — add paths: frontmatter (see llm#590)"
        fail=1
    done < <(find "$dir" -name '*.md' -type f | sort)
    return "$fail"
}

if [ "${1:-}" = "--selftest" ]; then
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    printf -- '---\npaths:\n  - "R/**"\n---\n# scoped\n' > "$tmp/scoped-rule.md"
    printf -- '# unscoped\nbody\n' > "$tmp/unscoped-rule.md"
    printf -- '---\ndescription: x\n---\n# mandatory\n' > "$tmp/bash-safety.md"
    pass=0
    rc=0
    out="$(audit "$tmp")" || rc=$?
    if [ "$rc" -eq 1 ]; then pass=$((pass+1)); else echo "FAIL: expected exit 1, got $rc"; fi
    case "$out" in *"unscoped-rule.md"*) pass=$((pass+1));; *) echo "FAIL: unscoped-rule.md not flagged";; esac
    case "$out" in *"bash-safety"*) echo "FAIL: allowlisted bash-safety flagged";; *) pass=$((pass+1));; esac
    echo "selftest: ${pass}/3 PASS"
    [ "$pass" -eq 3 ]
    exit
fi

RULES_DIR="${1:-/Users/johngavin/docs_gh/llm/.claude/rules}"
if [ ! -d "$RULES_DIR" ]; then
    echo "check_rule_scoping: rules dir not found: $RULES_DIR" >&2
    exit 2
fi
if audit "$RULES_DIR"; then
    echo "rule-scoping: OK — all non-mandatory rules carry paths: frontmatter"
    exit 0
fi
exit 1
