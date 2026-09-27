#!/usr/bin/env bash
# tests/test_agents_md_audit.sh — JohnGavin/llm#1276
#
# agents_md_audit.sh was rewritten to check that the NAMES AGENTS.md
# documents (agents table rows, the commands inline list, skills as named
# in SKILLS.md) actually exist on disk — and that everything real on disk
# is documented — instead of comparing hand-typed counts in AGENTS.md's
# headings (which just drifted every time a file was added or removed).
#
# This test:
#   1. Runs the audit against THIS repo's own real AGENTS.md and asserts
#      it reads that specific file (never the caller's cwd) and produces a
#      determinate result.
#   2. Falsifies it: a temp copy of AGENTS.md with one agent row deleted
#      must report that agent as missing, exit 1.
#   3. Falsifies it: a temp agents dir with one extra fake agent file must
#      report it as undocumented, exit 1 — using override env vars only,
#      so no real file under .claude/agents is ever touched.
#   4. Falsifies it: an unreadable AGENTS.md must exit 3 (INDETERMINATE),
#      never 0 or 1.
#   5. Confirms the cwd bug is actually fixed: running the script from an
#      unrelated directory still finds and reads the real AGENTS.md.
#
# Usage: bash tests/test_agents_md_audit.sh

set -uo pipefail

PASS=0
FAIL=0
ok()   { echo "ok     $*"; PASS=$((PASS+1)); }
fail() { echo "FAIL   $*"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AUDIT="$REPO_ROOT/.claude/scripts/agents_md_audit.sh"
AGENTS_MD="$REPO_ROOT/AGENTS.md"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"

# ── 0. Script parses ───────────────────────────────────────────────────────
if bash -n "$AUDIT"; then ok "bash -n agents_md_audit.sh"; else fail "bash -n agents_md_audit.sh"; fi

# ── 1. Real run against this repo's own AGENTS.md ──────────────────────────
out=$(bash "$AUDIT" 2>&1); rc=$?
if printf '%s' "$out" | grep -qF "$AGENTS_MD"; then
  ok "output names the AGENTS.md path it actually read: $AGENTS_MD"
else
  fail "output does not name the AGENTS.md path -> '$out'"
fi
case "$rc" in
  0|1) ok "real run exits determinate (0=ok or 1=DRIFT), got $rc" ;;
  *)   fail "real run exit code $rc is not 0 or 1 -> '$out'" ;;
esac
# The real agents/commands sections are known (as of this test's writing)
# to match disk exactly -- assert no agents-/commands- drift is reported,
# so a future regression in the agents/commands parser is caught even if
# skills drift (a separate, pre-existing SKILLS.md staleness) is present.
if printf '%s' "$out" | grep -qE 'agents-(missing|undocumented)'; then
  fail "unexpected agents-* drift in real run -> '$out'"
else
  ok "no agents-* drift in real run (agents table matches .claude/agents/*.md)"
fi
if printf '%s' "$out" | grep -qE 'commands-(missing|undocumented)'; then
  fail "unexpected commands-* drift in real run -> '$out'"
else
  ok "no commands-* drift in real run (commands list matches .claude/commands/*.md)"
fi

# ── 2. Falsify: delete one agent row from a temp copy of AGENTS.md ────────
FAKE_MD="$TMP/AGENTS_missing_agent.md"
# Delete the `critic` row specifically (a real, currently-documented agent).
grep -v '^| `critic` |' "$AGENTS_MD" > "$FAKE_MD"
# Pin CLAUDE_DIR to the REAL (read-only) .claude dir, so the on-disk side
# of the comparison is unchanged and the only difference is the one
# deleted row -- otherwise the default CLAUDE_DIR (derived as a sibling of
# the temp AGENTS.md, which has no .claude dir at all) would report every
# agent as missing, not just critic.
out=$(AGENTS_MD_AUDIT_PATH="$FAKE_MD" AGENTS_MD_AUDIT_CLAUDE_DIR="$REPO_ROOT/.claude" bash "$AUDIT" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'agents-undocumented:.*critic'; then
  ok "deleting the critic row -> DRIFT names critic as undocumented, exit 1"
else
  fail "deleting the critic row -> rc=$rc out='$out'"
fi

# ── 3. Falsify: extra fake agent file on disk, via override env vars only ─
# Build a throwaway CLAUDE_DIR containing only agents/commands/skills/rules
# dirs, so this never touches the real .claude/agents.
FAKE_CLAUDE="$TMP/fake_claude"
mkdir -p "$FAKE_CLAUDE/agents" "$FAKE_CLAUDE/commands" "$FAKE_CLAUDE/skills" "$FAKE_CLAUDE/rules" "$FAKE_CLAUDE/memory"
# Mirror the real agents.md table exactly, plus write matching stub files
# for every agent it names, so the ONLY difference is one extra fake agent
# file with no matching AGENTS.md row.
awk '/^## Agents/{p=1} p{print} p&&/^## Skills/{exit}' "$AGENTS_MD" \
  | grep -oE '^\| `[a-zA-Z0-9_-]+` \|' | grep -oE '`[a-zA-Z0-9_-]+`' | tr -d '`' \
  | while IFS= read -r name; do touch "$FAKE_CLAUDE/agents/${name}.md"; done
touch "$FAKE_CLAUDE/agents/totally-fake-agent-xyz.md"
out=$(AGENTS_MD_AUDIT_PATH="$AGENTS_MD" AGENTS_MD_AUDIT_CLAUDE_DIR="$FAKE_CLAUDE" bash "$AUDIT" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'agents-missing:.*totally-fake-agent-xyz' \
  || { [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'agents-undocumented:.*totally-fake-agent-xyz'; }; then
  ok "extra fake agent file on disk -> DRIFT names it as undocumented, exit 1"
else
  fail "extra fake agent file on disk -> rc=$rc out='$out'"
fi
if [ -f "$REPO_ROOT/.claude/agents/totally-fake-agent-xyz.md" ]; then
  fail "test accidentally touched the REAL .claude/agents directory"
else
  ok "no real .claude/agents file was touched by this falsification"
fi

# ── 3b. Regression: a `.` in a name (e.g. dplyr-1.1-patterns) must not be
#       misparsed as undocumented -- a name-character class of
#       [a-zA-Z0-9_-] (no dot) silently drops such names from the "listed"
#       side, making a real, correctly-documented skill look undocumented.
FAKE_SKILLS_MD="$TMP/SKILLS_dotted.md"
cat > "$FAKE_SKILLS_MD" <<'EOF'
# Skills by Category (1)
## Test
- `dotted-1.1-name` — a skill whose slug contains a period
EOF
FAKE_CLAUDE_DOTTED="$TMP/fake_claude_dotted"
mkdir -p "$FAKE_CLAUDE_DOTTED/skills/dotted-1.1-name" "$FAKE_CLAUDE_DOTTED/agents" "$FAKE_CLAUDE_DOTTED/commands"
out=$(AGENTS_MD_AUDIT_PATH="$AGENTS_MD" AGENTS_MD_AUDIT_CLAUDE_DIR="$FAKE_CLAUDE_DOTTED" AGENTS_MD_AUDIT_SKILLS_MD="$FAKE_SKILLS_MD" bash "$AUDIT" 2>&1)
if printf '%s' "$out" | grep -q 'dotted-1.1-name'; then
  fail "dotted skill name 'dotted-1.1-name' wrongly reported as drift -> '$out'"
else
  ok "dotted skill name 'dotted-1.1-name' matches listed<->actual, no false drift"
fi

# ── 4. Falsify: unreadable AGENTS.md -> exit 3, never 0 or 1 ──────────────
UNREADABLE="$TMP/unreadable_AGENTS.md"
echo "not real" > "$UNREADABLE"
chmod 000 "$UNREADABLE"
out=$(AGENTS_MD_AUDIT_PATH="$UNREADABLE" bash "$AUDIT" 2>&1); rc=$?
chmod 644 "$UNREADABLE" 2>/dev/null || true
if [ "$rc" -eq 3 ]; then
  ok "unreadable AGENTS.md -> exit 3 (INDETERMINATE): '$out'"
else
  fail "unreadable AGENTS.md -> expected exit 3, got $rc: '$out'"
fi

# Also: a path that does not exist at all -> exit 3.
out=$(AGENTS_MD_AUDIT_PATH="$TMP/does-not-exist.md" bash "$AUDIT" 2>&1); rc=$?
if [ "$rc" -eq 3 ]; then
  ok "nonexistent AGENTS.md path -> exit 3 (INDETERMINATE)"
else
  fail "nonexistent AGENTS.md path -> expected exit 3, got $rc: '$out'"
fi

# ── 5. The cwd bug is fixed: running from elsewhere still finds THIS repo's
#       AGENTS.md (no AGENTS_MD_AUDIT_PATH override — exercises the git
#       -C "$(dirname "$0")" resolution path directly) ────────────────────
out=$(cd "$TMP" && bash "$AUDIT" 2>&1); rc=$?
if printf '%s' "$out" | grep -qF "$AGENTS_MD"; then
  ok "invoked from an unrelated cwd ($TMP) -> still reads $AGENTS_MD"
else
  fail "invoked from an unrelated cwd -> did not read the real AGENTS.md: '$out'"
fi

# ── 6. --help exits 0; an unknown argument exits 2 (usage error) ──────────
if bash "$AUDIT" --help >/dev/null 2>&1; then ok "--help exits 0"; else fail "--help did not exit 0"; fi
bash "$AUDIT" --bogus-flag >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then ok "unknown argument -> exit 2 (usage error)"; else fail "unknown argument -> expected exit 2, got $rc"; fi

echo "---"
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
