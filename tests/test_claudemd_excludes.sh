#!/usr/bin/env bash
# tests/test_claudemd_excludes.sh
# Asserts .claude/settings.json `claudeMdExcludes` drops the WORKTREE copies of
# .claude/rules/** (so an llm worktree session loads each always-on rule once,
# via ~/.claude/rules -> main checkout) and never the main-checkout copy.
#
# Matcher approximation: Claude Code matches globs against absolute paths with
# its own matcher; here we approximate with a small glob->regex translation
# where `**` matches any characters including `/` and `*` matches within one
# path segment. `/**/` additionally matches a single `/` (zero directories).
# Close enough for these patterns; not the identical implementation.
# Exit 0 = all pass. Exit 1 = at least one failure.
set -uo pipefail

SETTINGS="${1:-.claude/settings.json}"

python3 - "$SETTINGS" << 'EOF'
import json, re, sys

d = json.load(open(sys.argv[1]))
pats = d.get("claudeMdExcludes", [])
fails = 0

def ok(msg): print("PASS: " + msg)
def bad(msg):
    global fails
    fails += 1
    print("FAIL: " + msg)

def to_re(g):
    out, i = "", 0
    while i < len(g):
        if g.startswith("/**/", i):
            out += "/(?:.*/)?"; i += 4
        elif g.startswith("**", i):
            out += ".*"; i += 2
        elif g[i] == "*":
            out += "[^/]*"; i += 1
        else:
            out += re.escape(g[i]); i += 1
    return re.compile("^" + out + "$")

def matches(path): return [p for p in pats if to_re(p).match(path)]

required = [
    "/Users/johngavin/docs_gh/worktrees/llm/**/.claude/rules/**",
    "/Users/johngavin/docs_gh/llm/.claude/worktrees/**/.claude/rules/**",
    "/Users/johngavin/worktrees/llm/**/.claude/rules/**",
]
for r in required:
    (ok if r in pats else bad)("pattern present: " + r)

main_rule = "/Users/johngavin/docs_gh/llm/.claude/rules/bash-safety.md"
m = matches(main_rule)
(bad if m else ok)("main-checkout rule not excluded" + (": " + str(m) if m else ""))

samples = [
    "/Users/johngavin/docs_gh/worktrees/llm/feat/x/.claude/rules/bash-safety.md",
    "/Users/johngavin/docs_gh/llm/.claude/worktrees/agent-abc/.claude/rules/bash-safety.md",
    "/Users/johngavin/worktrees/llm/fix/y/.claude/rules/bash-safety.md",
]
for s in samples:
    (ok if matches(s) else bad)("worktree rule excluded: " + s)

# No CLAUDE.md may be excluded.
for c in ["/Users/johngavin/docs_gh/llm/CLAUDE.md",
          "/Users/johngavin/docs_gh/llm/.claude/CLAUDE.md",
          "/Users/johngavin/docs_gh/worktrees/llm/feat/x/.claude/CLAUDE.md"]:
    (bad if matches(c) else ok)("CLAUDE.md not excluded: " + c)

print("fails=%d" % fails)
sys.exit(1 if fails else 0)
EOF
