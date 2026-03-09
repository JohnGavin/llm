#!/usr/bin/env bash
# validate_claude_md.sh - Check bidirectional mapping between CLAUDE.md and actual files
# Runs at session start. Informational only (exits 0 even on mismatches).

set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"
SKILLS_DIR="$CLAUDE_DIR/skills"
RULES_DIR="$CLAUDE_DIR/rules"
COMMANDS_DIR="$CLAUDE_DIR/commands"
SETTINGS_JSON="$CLAUDE_DIR/settings.json"

has_mismatch=0

echo "CLAUDE.md Mapping Validation"
echo "============================="

# --- SKILLS ---
# Extract skill names from Skills section (handles both old and merged formats).
# Old: ## Skills ... `skill-name`
# New: ## Skills by Category ... `skill-name` — description
referenced_skills=$(
  sed -n '/^## Skills/,/^## [^S]/p' "$CLAUDE_MD" \
    | grep -oE '`[a-z][a-z0-9.-]+`' \
    | sed -E 's/`([a-z][a-z0-9.-]+)`/\1/' \
    | sort -u
)

# Get skills on disk (directories with SKILL.md, or .md files at top level)
disk_skills=""
if [ -d "$SKILLS_DIR" ]; then
  # Directories containing SKILL.md
  for d in "$SKILLS_DIR"/*/; do
    [ -d "$d" ] || continue
    if [ -f "${d}SKILL.md" ]; then
      disk_skills="${disk_skills}$(basename "$d")"$'\n'
    fi
  done
  # Top-level .md files (excluding README.md and SKILLS_UPDATE*)
  for f in "$SKILLS_DIR"/*.md; do
    [ -f "$f" ] || continue
    bname=$(basename "$f" .md)
    case "$bname" in
      README|SKILLS_UPDATE*) continue ;;
    esac
    disk_skills="${disk_skills}${bname}"$'\n'
  done
  disk_skills=$(echo "$disk_skills" | grep -v '^$' | sort -u)
fi

n_referenced=$(echo "$referenced_skills" | grep -c . || echo 0)
n_disk=$(echo "$disk_skills" | grep -c . || echo 0)

# Find missing on disk (referenced but not present)
missing_skills=""
while IFS= read -r skill; do
  [ -z "$skill" ] && continue
  if ! echo "$disk_skills" | grep -qx "$skill"; then
    missing_skills="$missing_skills $skill"
  fi
done <<< "$referenced_skills"

# Find orphaned (on disk but not referenced) - these are WARNINGS
orphaned_skills=""
while IFS= read -r skill; do
  [ -z "$skill" ] && continue
  if ! echo "$referenced_skills" | grep -qx "$skill"; then
    orphaned_skills="$orphaned_skills $skill"
  fi
done <<< "$disk_skills"

n_orphaned=$(echo "$orphaned_skills" | wc -w | tr -d ' ')
missing_skills_trimmed=$(echo "$missing_skills" | xargs)

if [ -z "$missing_skills_trimmed" ]; then
  echo "Skills:   OK ($n_referenced referenced, $n_disk on disk, $n_orphaned orphaned)"
else
  echo "Skills:   MISMATCH"
  echo "  Missing on disk: $missing_skills_trimmed"
  has_mismatch=1
fi
if [ "$n_orphaned" -gt 0 ]; then
  echo "  Orphaned (not in CLAUDE.md):$orphaned_skills"
fi

# --- RULES ---
if [ -d "$RULES_DIR" ]; then
  n_rules=$(ls "$RULES_DIR"/*.md 2>/dev/null | wc -l | tr -d ' ')
  echo "Rules:    OK ($n_rules files on disk)"
else
  echo "Rules:    WARN (no rules directory)"
fi

# --- COMMANDS ---
# Extract command names from Commands section (handles both old and merged formats).
# Old: - `/cmd` - description
# New: | `/cmd` | description |
referenced_cmds=$(
  sed -n '/^## \(Custom \)\{0,1\}Commands/,/^## /p' "$CLAUDE_MD" \
    | grep -oE '`/[a-z][a-z0-9-]+`' \
    | sed -E 's/`\/([a-z][a-z0-9-]+)`/\1/' \
    | sort -u
)

disk_cmds=""
if [ -d "$COMMANDS_DIR" ]; then
  for f in "$COMMANDS_DIR"/*.md; do
    [ -f "$f" ] || continue
    disk_cmds="${disk_cmds}$(basename "$f" .md)"$'\n'
  done
  disk_cmds=$(echo "$disk_cmds" | grep -v '^$' | sort -u)
fi

n_ref_cmds=$(echo "$referenced_cmds" | grep -c . || echo 0)
n_disk_cmds=$(echo "$disk_cmds" | grep -c . || echo 0)

missing_cmds=""
while IFS= read -r cmd; do
  [ -z "$cmd" ] && continue
  if ! echo "$disk_cmds" | grep -qx "$cmd"; then
    missing_cmds="$missing_cmds $cmd"
  fi
done <<< "$referenced_cmds"

orphaned_cmds=""
while IFS= read -r cmd; do
  [ -z "$cmd" ] && continue
  if ! echo "$referenced_cmds" | grep -qx "$cmd"; then
    orphaned_cmds="$orphaned_cmds $cmd"
  fi
done <<< "$disk_cmds"

n_orphaned_cmds=$(echo "$orphaned_cmds" | wc -w | tr -d ' ')
missing_cmds_trimmed=$(echo "$missing_cmds" | xargs)

if [ -z "$missing_cmds_trimmed" ]; then
  echo "Commands: OK ($n_ref_cmds referenced, $n_disk_cmds on disk, $n_orphaned_cmds orphaned)"
else
  echo "Commands: MISMATCH"
  echo "  Missing on disk: $missing_cmds_trimmed"
  has_mismatch=1
fi
if [ "$n_orphaned_cmds" -gt 0 ]; then
  echo "  Orphaned (not in CLAUDE.md):$orphaned_cmds"
fi

# --- HOOKS ---
if [ -f "$SETTINGS_JSON" ]; then
  n_hooks=$(grep -c '"type": "command"' "$SETTINGS_JSON" 2>/dev/null || echo 0)
  echo "Hooks:    OK ($n_hooks hook commands in settings.json)"
else
  echo "Hooks:    WARN (no settings.json found)"
fi

# --- MEMORY ---
MEMORY_DIR=""
for d in "$CLAUDE_DIR"/projects/*/memory; do
  [ -d "$d" ] && MEMORY_DIR="$d" && break
done

if [ -n "$MEMORY_DIR" ] && [ -f "$MEMORY_DIR/MEMORY.md" ]; then
  n_mem_files=$(ls "$MEMORY_DIR"/*.md 2>/dev/null | wc -l | tr -d ' ')
  echo "Memory:   OK ($n_mem_files files)"
else
  echo "Memory:   WARN (MEMORY.md not found)"
fi

# --- RULES YAML FRONTMATTER ---
if [ -d "$RULES_DIR" ]; then
  n_no_yaml=0
  no_yaml_files=""
  for f in "$RULES_DIR"/*.md; do
    [ -f "$f" ] || continue
    if ! head -1 "$f" | grep -q '^---$'; then
      n_no_yaml=$((n_no_yaml + 1))
      no_yaml_files="$no_yaml_files $(basename "$f")"
    fi
  done
  if [ "$n_no_yaml" -gt 0 ]; then
    echo "Rules FM: WARN: $n_no_yaml files missing YAML paths: frontmatter:$no_yaml_files"
  else
    echo "Rules FM: OK (all have YAML frontmatter)"
  fi
fi

# --- DUPLICATE SECTIONS IN CLAUDE.MD ---
if [ -f "$CLAUDE_MD" ]; then
  dupes=$(grep -E '^## ' "$CLAUDE_MD" | sort | uniq -d)
  if [ -n "$dupes" ]; then
    echo "Sections: WARN: duplicate headings in CLAUDE.md:"
    echo "$dupes" | sed 's/^/  /'
  else
    echo "Sections: OK (no duplicate headings)"
  fi
fi

echo ""
if [ "$has_mismatch" -eq 1 ]; then
  echo "ACTION NEEDED: Fix mismatches above"
else
  echo "All mappings consistent."
fi

exit 0
