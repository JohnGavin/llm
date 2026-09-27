#!/usr/bin/env bash
# agents_md_audit.sh — verify AGENTS.md matches reality, by NAME not by
# hand-typed count (JohnGavin/llm#1276).
#
# The old version compared hand-typed counts in AGENTS.md's headings
# ("Skills (73)", "Rules (91)", ...) against `ls | wc -l` on the matching
# directory. Per `dynamic-prose-values`/"one home per value", a count that
# has to be hand-bumped every time a file is added or removed is a defect,
# not a fact worth stating — it drifts the moment anyone forgets, and
# bumping it back to match only restarts the same drift. AGENTS.md no
# longer carries these counts in its headings; this script computes them
# for DISPLAY only and checks what actually matters: do the specific names
# AGENTS.md documents still exist, and does anything real go undocumented.
#
# Checks, by name, bidirectionally:
#   agents   — "## Agents" table rows (`| \`name\` | model | ... |`)
#              vs  <claude-dir>/agents/*.md
#   commands — "## Commands" inline `` `/name`(`/alias`) `` list
#              vs  <claude-dir>/commands/*.md
#   skills   — AGENTS.md does not name skills individually; it points at
#              SKILLS.md ("Full categorised list at `.claude/SKILLS.md`").
#              So the names actually audited come from THAT file
#              (`- \`skill-name\` — ...` list items) vs <claude-dir>/skills/*/SKILL.md
#
# Display-only counts (not name-diffed — AGENTS.md's Rules/Memory sections
# are deliberately curated references, not exhaustive listings, so a
# missing/extra name there is not a defect the way it is for agents/
# commands/skills):
#   rules  — <claude-dir>/rules/*.md
#   memory — <memory-dir>/*.md
#
# AGENTS.md is resolved from THIS SCRIPT'S OWN repo
# (`git -C "$(dirname "$0")" rev-parse --show-toplevel`), never from the
# caller's current directory — the old version searched
# `"AGENTS.md" "$HOME/docs_gh/llm/AGENTS.md"` relative to `pwd`/a hardcoded
# path, so a caller running from a different directory (or a worktree not
# at that hardcoded path) could silently read the wrong file, or none.
#
# Override for testing (never required for normal use):
#   AGENTS_MD_AUDIT_PATH        - AGENTS.md path
#   AGENTS_MD_AUDIT_CLAUDE_DIR  - .claude dir holding agents/commands/skills/rules
#   AGENTS_MD_AUDIT_SKILLS_MD   - path to SKILLS.md
#   AGENTS_MD_AUDIT_MEMORY_DIR  - path to the memory dir
#
# Exit codes (see `exit-code-conventions` rule):
#   0 ok            1 DRIFT            2 usage error            3 INDETERMINATE
#   (AGENTS.md — or the repo it should live in — could not be resolved or
#   read; or SKILLS.md is unreadable and nothing else drifted)
set -uo pipefail

usage() {
  cat <<'EOF'
Usage: agents_md_audit.sh [--help]

Verifies AGENTS.md's Agents/Commands/Skills sections name what actually
exists on disk. See the file header for the full check list and the
AGENTS_MD_AUDIT_* environment overrides used by this script's own tests.
EOF
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
if [ $# -gt 0 ]; then
  echo "agents_md_audit.sh: unknown argument: $1" >&2
  usage >&2
  exit 2
fi

# ── Resolve AGENTS.md ────────────────────────────────────────────────────
if [ -n "${AGENTS_MD_AUDIT_PATH:-}" ]; then
  AGENTS_MD="$AGENTS_MD_AUDIT_PATH"
else
  _script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || _script_dir=""
  _repo_root=""
  if [ -n "$_script_dir" ]; then
    _repo_root=$(git -C "$_script_dir" rev-parse --show-toplevel 2>/dev/null) || _repo_root=""
  fi
  if [ -z "$_repo_root" ]; then
    echo "AGENTS.md: INDETERMINATE (could not resolve this script's own repo root from $_script_dir)"
    exit 3
  fi
  AGENTS_MD="$_repo_root/AGENTS.md"
fi

if [ ! -f "$AGENTS_MD" ] || [ ! -r "$AGENTS_MD" ]; then
  echo "AGENTS.md: INDETERMINATE (not found or unreadable at $AGENTS_MD)"
  exit 3
fi

CLAUDE_DIR="${AGENTS_MD_AUDIT_CLAUDE_DIR:-$(dirname "$AGENTS_MD")/.claude}"
SKILLS_MD="${AGENTS_MD_AUDIT_SKILLS_MD:-$CLAUDE_DIR/SKILLS.md}"
MEMORY_DIR="${AGENTS_MD_AUDIT_MEMORY_DIR:-$CLAUDE_DIR/memory}"

# ── Helpers ───────────────────────────────────────────────────────────────
# Print the lines between a "^## <heading_re>" line and the next "^## " line.
section_body() {
  local heading_re="$1" file="$2"
  awk -v re="$heading_re" '
    $0 ~ "^## " re {p=1; next}
    p && /^## / {exit}
    p {print}
  ' "$file" 2>/dev/null
}

sorted_uniq() { LC_ALL=C sort -u; }

# missing = named in AGENTS.md/source file but absent on disk
# extra   = present on disk but not named
# Prints "<label>-missing:a,b <label>-undocumented:c,d" (only the parts that
# are non-empty); prints nothing when both sides match.
diff_names() {
  local label="$1" listed="$2" actual="$3" missing extra out=""
  missing=$(comm -23 <(printf '%s\n' "$listed") <(printf '%s\n' "$actual") 2>/dev/null | grep -v '^$')
  extra=$(comm -13 <(printf '%s\n' "$listed") <(printf '%s\n' "$actual") 2>/dev/null | grep -v '^$')
  [ -n "$missing" ] && out="${out}${label}-missing:$(printf '%s' "$missing" | tr '\n' ',' | sed 's/,$//') "
  [ -n "$extra" ]   && out="${out}${label}-undocumented:$(printf '%s' "$extra" | tr '\n' ',' | sed 's/,$//') "
  printf '%s' "$out"
}

count_nonblank() { grep -c . 2>/dev/null || true; }

# ── 1. Agents: "| `name` | model | ... |" table rows ──────────────────────
agents_listed=$(section_body "Agents" "$AGENTS_MD" | grep -oE '^\| `[a-zA-Z0-9_.-]+` \|' | grep -oE '`[a-zA-Z0-9_.-]+`' | tr -d '`' | sorted_uniq)
agents_actual=$(ls "$CLAUDE_DIR"/agents/*.md 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/\.md$//' | sorted_uniq)

# ── 2. Commands: inline `` `/name`(`/alias`) `` list (first content line) ──
_commands_line=$(section_body "Commands" "$AGENTS_MD" | grep -m1 '.')
commands_listed=$(printf '%s\n' "$_commands_line" | grep -oE '/[a-zA-Z0-9_.-]+' | sed 's|^/||' | sorted_uniq)
commands_actual=$(ls "$CLAUDE_DIR"/commands/*.md 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/\.md$//' | sorted_uniq)

# ── 3. Skills: named in SKILLS.md, not in AGENTS.md itself ────────────────
skills_source_ok=1
if [ -f "$SKILLS_MD" ] && [ -r "$SKILLS_MD" ]; then
  skills_listed=$(grep -oE '^- `[a-zA-Z0-9_.-]+`' "$SKILLS_MD" | grep -oE '`[a-zA-Z0-9_.-]+`' | tr -d '`' | sorted_uniq)
  # A skill is a directory holding SKILL.md -- the only shape Claude Code
  # loads. Counting every directory would flag local, gitignored non-skill
  # dirs (e.g. skills/generated/, skills/synced/) as undocumented skills,
  # and would miss a flat skills/<name>.md that never loads.
  skills_actual=$(ls "$CLAUDE_DIR"/skills/*/SKILL.md 2>/dev/null | xargs -n1 dirname 2>/dev/null | xargs -n1 basename 2>/dev/null | sorted_uniq)
else
  skills_listed=""
  skills_actual=""
  skills_source_ok=0
fi

# ── 4/5. Rules + Memory: display-only counts (curated, non-exhaustive) ────
rules_actual_n=$(ls "$CLAUDE_DIR"/rules/*.md 2>/dev/null | wc -l | tr -d ' ')
memory_actual_n=$(ls "$MEMORY_DIR"/*.md 2>/dev/null | wc -l | tr -d ' ')

# ── Assemble drift ─────────────────────────────────────────────────────────
drift=""
drift="${drift}$(diff_names agents "$agents_listed" "$agents_actual")"
drift="${drift}$(diff_names commands "$commands_listed" "$commands_actual")"
if [ "$skills_source_ok" = "1" ]; then
  drift="${drift}$(diff_names skills "$skills_listed" "$skills_actual")"
fi

agents_n=$(printf '%s\n' "$agents_actual" | count_nonblank)
commands_n=$(printf '%s\n' "$commands_actual" | count_nonblank)
skills_n=$(printf '%s\n' "$skills_actual" | count_nonblank)

# An unreadable SKILLS.md leaves only the skills question unanswered: agent or
# command drift found without it is still a determinate DRIFT (exit 1). With
# no other drift, the result is INDETERMINATE (exit 3), never "ok".
skills_note=""
[ "$skills_source_ok" = "1" ] || skills_note=" [skills not checked: SKILLS.md not found or unreadable at $SKILLS_MD]"

if [ -n "$drift" ]; then
  echo "AGENTS.md ($AGENTS_MD): DRIFT ${drift}${skills_note}"
  exit 1
elif [ "$skills_source_ok" != "1" ]; then
  echo "AGENTS.md ($AGENTS_MD): INDETERMINATE agents and commands ok${skills_note}"
  exit 3
else
  echo "AGENTS.md ($AGENTS_MD): ok (${agents_n}a ${commands_n}c ${skills_n}s ${rules_actual_n}r ${memory_actual_n}m)"
  exit 0
fi
