#!/usr/bin/env bash
# session_init.sh - Unified session start checks
# Merges: startup_check.sh, validate_claude_md.sh, config_size_check.sh, count_skill_tokens.sh
# Hook: SessionStart

set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"
SKILLS_DIR="$CLAUDE_DIR/skills"
RULES_DIR="$CLAUDE_DIR/rules"
COMMANDS_DIR="$CLAUDE_DIR/commands"
AGENTS_DIR="$CLAUDE_DIR/agents"
SETTINGS_JSON="$CLAUDE_DIR/settings.json"

MEMORY_DIR=""
for d in "$CLAUDE_DIR"/projects/*/memory; do
  [ -d "$d" ] && MEMORY_DIR="$d" && break
done

# ── Phase 1: Environment ──────────────────────────────────────────────
phase_env() {
  if [ "$IN_NIX_SHELL" = "impure" ] || [ "$IN_NIX_SHELL" = "pure" ] || [ "${IN_NIX_SHELL:-}" = "1" ]; then
    echo "Nix Shell: active ($IN_NIX_SHELL)"
  else
    echo "Nix Shell: WARNING — not in nix shell"
  fi
}

# ── Phase 2: Mapping Validation ───────────────────────────────────────
phase_mappings() {
  local has_mismatch=0

  # Skills: referenced in CLAUDE.md vs on disk
  local referenced_skills disk_skills
  referenced_skills=$(
    sed -n '/^## Skills/,/^## [^S]/p' "$CLAUDE_MD" 2>/dev/null \
      | grep -oE '`[a-z][a-z0-9.-]+`' \
      | sed -E 's/`([a-z][a-z0-9.-]+)`/\1/' \
      | sort -u
  )
  disk_skills=""
  if [ -d "$SKILLS_DIR" ]; then
    for d in "$SKILLS_DIR"/*/; do
      [ -d "$d" ] && [ -f "${d}SKILL.md" ] && disk_skills="${disk_skills}$(basename "$d")"$'\n'
    done
    for f in "$SKILLS_DIR"/*.md; do
      [ -f "$f" ] || continue
      local bname; bname=$(basename "$f" .md)
      case "$bname" in README|SKILLS_UPDATE*) continue ;; esac
      disk_skills="${disk_skills}${bname}"$'\n'
    done
    disk_skills=$(echo "$disk_skills" | grep -v '^$' | sort -u)
  fi

  local n_ref n_disk n_orphaned=0
  n_ref=$(echo "$referenced_skills" | grep -c . || echo 0)
  n_disk=$(echo "$disk_skills" | grep -c . || echo 0)

  local missing=""
  while IFS= read -r s; do
    [ -z "$s" ] && continue
    echo "$disk_skills" | grep -qx "$s" || missing="$missing $s"
  done <<< "$referenced_skills"

  local orphaned=""
  while IFS= read -r s; do
    [ -z "$s" ] && continue
    echo "$referenced_skills" | grep -qx "$s" || { orphaned="$orphaned $s"; n_orphaned=$((n_orphaned + 1)); }
  done <<< "$disk_skills"

  missing=$(echo "$missing" | xargs)
  if [ -z "$missing" ]; then
    echo "Skills:   OK ($n_ref referenced, $n_disk on disk, $n_orphaned orphaned)"
  else
    echo "Skills:   MISMATCH — missing on disk: $missing"
    has_mismatch=1
  fi
  [ "$n_orphaned" -gt 0 ] && echo "  Orphaned:$orphaned"

  # Rules
  if [ -d "$RULES_DIR" ]; then
    local n_rules; n_rules=$(ls "$RULES_DIR"/*.md 2>/dev/null | wc -l | tr -d ' ')
    echo "Rules:    OK ($n_rules files on disk)"
    # YAML frontmatter check
    local n_no_yaml=0 no_yaml_files=""
    for f in "$RULES_DIR"/*.md; do
      [ -f "$f" ] || continue
      head -1 "$f" | grep -q '^---$' || { n_no_yaml=$((n_no_yaml + 1)); no_yaml_files="$no_yaml_files $(basename "$f")"; }
    done
    [ "$n_no_yaml" -gt 0 ] && echo "Rules FM: WARN: $n_no_yaml missing frontmatter:$no_yaml_files"
  fi

  # Commands
  local ref_cmds disk_cmds
  ref_cmds=$(
    sed -n '/^## \(Custom \)\{0,1\}Commands/,/^## /p' "$CLAUDE_MD" 2>/dev/null \
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
  local n_rc n_dc
  n_rc=$(echo "$ref_cmds" | grep -c . || echo 0)
  n_dc=$(echo "$disk_cmds" | grep -c . || echo 0)
  local miss_c=""
  while IFS= read -r c; do
    [ -z "$c" ] && continue
    echo "$disk_cmds" | grep -qx "$c" || miss_c="$miss_c $c"
  done <<< "$ref_cmds"
  miss_c=$(echo "$miss_c" | xargs)
  if [ -z "$miss_c" ]; then
    echo "Commands: OK ($n_rc referenced, $n_dc on disk)"
  else
    echo "Commands: MISMATCH — missing: $miss_c"
    has_mismatch=1
  fi

  # Hooks count
  if [ -f "$SETTINGS_JSON" ]; then
    local n_hooks; n_hooks=$(grep -c '"type": "command"' "$SETTINGS_JSON" 2>/dev/null || echo 0)
    echo "Hooks:    OK ($n_hooks hook commands in settings.json)"
  fi

  # Memory
  if [ -n "$MEMORY_DIR" ] && [ -f "$MEMORY_DIR/MEMORY.md" ]; then
    local n_mem; n_mem=$(ls "$MEMORY_DIR"/*.md 2>/dev/null | wc -l | tr -d ' ')
    echo "Memory:   OK ($n_mem files)"
  fi

  # Duplicate sections
  if [ -f "$CLAUDE_MD" ]; then
    local dupes; dupes=$(grep -E '^## ' "$CLAUDE_MD" | sort | uniq -d)
    if [ -n "$dupes" ]; then
      echo "Sections: WARN: duplicate headings"
    fi
  fi

  [ "$has_mismatch" -eq 0 ] && echo "All mappings consistent." || echo "ACTION NEEDED: Fix mismatches above"
}

# ── Phase 3: Size Audit ──────────────────────────────────────────────
phase_sizes() {
  check_file() {
    local file="$1" warn="$2" fail="$3" label="$4"
    [ -f "$file" ] || return
    local lines; lines=$(timeout 5 wc -l < "$file" 2>/dev/null || echo 0)
    if [ "$lines" -gt "$fail" ]; then
      echo "$label: $lines lines  FAIL (>$fail)"
    elif [ "$lines" -gt "$warn" ]; then
      echo "$label: $lines lines  WARN (>$warn)"
    else
      echo "$label: $lines lines  OK"
    fi
  }

  check_file "$CLAUDE_MD" 200 500 "CLAUDE.md"
  [ -n "$MEMORY_DIR" ] && [ -f "$MEMORY_DIR/MEMORY.md" ] && check_file "$MEMORY_DIR/MEMORY.md" 150 200 "MEMORY.md"

  # Directory summaries (rules, skills, agents, commands)
  for dir_info in "$RULES_DIR:150:Rules" "$SKILLS_DIR:500:Skills" "$AGENTS_DIR:300:Agents" "$COMMANDS_DIR:200:Commands"; do
    IFS=: read -r dir limit label <<< "$dir_info"
    [ -d "$dir" ] || continue
    local n=0 max_l=0 max_f="" total=0 n_warn=0
    local find_pattern="*.md"
    if [ "$label" = "Skills" ]; then
      while IFS= read -r -d '' f; do
        local l; l=$(timeout 5 wc -l < "$f" 2>/dev/null || echo 0)
        n=$((n + 1)); total=$((total + l))
        local parent; parent=$(basename "$(dirname "$f")")
        [ "$l" -gt "$max_l" ] && { max_l=$l; max_f="$parent"; }
        [ "$l" -gt "$limit" ] && n_warn=$((n_warn + 1))
      done < <(find -L "$dir" -name "SKILL.md" -print0 2>/dev/null)
    else
      for f in "$dir"/*.md; do
        [ -f "$f" ] || continue
        local l; l=$(timeout 5 wc -l < "$f" 2>/dev/null || echo 0)
        n=$((n + 1)); total=$((total + l))
        [ "$l" -gt "$max_l" ] && { max_l=$l; max_f=$(basename "$f"); }
        [ "$l" -gt "$limit" ] && n_warn=$((n_warn + 1))
      done
    fi
    if [ "$n" -gt 0 ]; then
      local avg=$((total / n))
      local msg="$label ($n):  avg $avg, max $max_l ($max_f)"
      [ "$n_warn" -gt 0 ] && msg="$msg  WARN: $n_warn files >$limit" || msg="$msg  OK"
      echo "$msg"
    fi
  done
}

# ── Phase 4: Skill Token Audit ────────────────────────────────────────
phase_skill_tokens() {
  local warn_count=0 total_skills=0 total_lines=0
  local skill_limit=500

  if [ -d "$SKILLS_DIR" ]; then
    while IFS= read -r -d '' skill_file; do
      local lines; lines=$(wc -l < "$skill_file" 2>/dev/null || echo 0)
      total_skills=$((total_skills + 1))
      total_lines=$((total_lines + lines))
      if [ "$lines" -gt "$skill_limit" ]; then
        local parent; parent=$(basename "$(dirname "$skill_file")")
        echo "WARN: $parent SKILL.md has $lines lines (limit: $skill_limit)"
        warn_count=$((warn_count + 1))
      fi
      # Count reference files
      local ref_dir; ref_dir="$(dirname "$skill_file")/references"
      if [ -d "$ref_dir" ]; then
        for rf in "$ref_dir"/*.md; do
          [ -f "$rf" ] || continue
          local rl; rl=$(wc -l < "$rf" 2>/dev/null || echo 0)
          total_lines=$((total_lines + rl))
        done
      fi
    done < <(find -L "$SKILLS_DIR" -name "SKILL.md" -print0 2>/dev/null)
  fi

  echo "Skills audit: $total_skills skills, $total_lines total lines, $warn_count warnings"
  [ "$warn_count" -gt 0 ] && echo "ACTION: $warn_count skill(s) exceed $skill_limit line limit" || echo "All skills within limits."
}

# ── Phase 5: ctx.yaml Cache Audit ─────────────────────────────────────
phase_ctx_audit() {
  local ctx_cache="$HOME/docs_gh/proj/data/llm/content/inst/ctx/external"
  [ -f "DESCRIPTION" ] || { echo "No DESCRIPTION file — skipping ctx audit"; return; }
  [ -d "$ctx_cache" ] || { echo "No ctx cache dir — skipping"; return; }

  # Use R to parse DESCRIPTION and check version-stamped ctx files
  # Output: one line per package as "STATUS:pkg" (OK, STALE, MISSING)
  local audit_output
  audit_output=$(timeout 10 Rscript -e '
    d <- read.dcf("DESCRIPTION", fields = c("Imports","Suggests","Depends"))
    raw <- paste(na.omit(as.character(d)), collapse = ",")
    p <- trimws(unlist(strsplit(raw, ",")))
    p <- sub("\\s*\\(.*", "", p)
    base_pkgs <- c("base","compiler","datasets","graphics","grDevices","grid",
      "methods","parallel","splines","stats","stats4","tcltk","tools","utils")
    p <- p[nzchar(p) & !p %in% c("R", base_pkgs)]
    cache <- Sys.getenv("HOME") |> file.path("docs_gh/proj/data/llm/content/inst/ctx/external")
    for (pkg in sort(unique(p))) {
      ver <- tryCatch(as.character(packageVersion(pkg)), error = function(e) "unknown")
      f <- file.path(cache, paste0(pkg, "@", ver, ".ctx.yaml"))
      if (file.exists(f)) {
        age <- as.numeric(difftime(Sys.time(), file.mtime(f), units = "days"))
        cat(if (age > 30) paste0("STALE:", pkg) else paste0("OK:", pkg), "\n")
      } else {
        # Check for any version
        any_ver <- list.files(cache, pattern = paste0("^", gsub("\\\\.", "\\\\\\\\.", pkg), "@"), full.names = TRUE)
        if (length(any_ver) > 0) cat(paste0("OTHER_VER:", pkg), "\n")
        else cat(paste0("MISSING:", pkg), "\n")
      }
    }
  ' 2>/dev/null) || true
  [ -z "$audit_output" ] && { echo "Could not parse DESCRIPTION"; return; }

  local n_ok=0 n_stale=0 n_missing=0 n_other=0 missing_list=""
  echo "$audit_output" | {
    while IFS=: read -r status pkg; do
      case "$status" in
        OK) n_ok=$((n_ok + 1)) ;;
        STALE) n_stale=$((n_stale + 1)) ;;
        OTHER_VER) n_other=$((n_other + 1)) ;;
        MISSING) n_missing=$((n_missing + 1)); missing_list="$missing_list $pkg" ;;
      esac
    done
    echo "ctx cache: $n_ok OK, $n_stale stale, $n_other wrong-version, $n_missing missing"
    [ "$n_missing" -gt 0 ] && echo "  Missing:$missing_list"
    [ "$((n_missing + n_stale + n_other))" -gt 0 ] && echo "  Fix at session end: /bye runs ctx_sync()"
    true
  }
}

# ── Phase 6: R-universe Build Status ──────────────────────────────────
phase_r_universe() {
  # Check R-universe build status for all registered packages (~2s)
  local status
  if ! status=$(timeout 10 curl -fsS "https://johngavin.r-universe.dev/api/packages" 2>/dev/null); then
    echo "R-universe: could not reach API"
    return
  fi
  [ -z "$status" ] && { echo "R-universe: could not reach API"; return; }

  local result
  result=$(echo "$status" | timeout 5 Rscript -e '
    d <- jsonlite::fromJSON(readLines("stdin", warn = FALSE))
    if (!is.data.frame(d) || nrow(d) == 0) { cat("No packages\n"); quit() }
    fails <- d[d[["_status"]] != "success", , drop = FALSE]
    ok <- sum(d[["_status"]] == "success")
    cat("R-universe:", ok, "OK,", nrow(fails), "failed\n")
    if (nrow(fails) > 0) {
      for (i in seq_len(nrow(fails))) {
        cat("  FAIL:", fails$Package[i], "—", fails[["_buildurl"]][i], "\n")
      }
    }
  ' 2>/dev/null) || true
  [ -n "$result" ] && echo "$result" || echo "R-universe: parse error"
}

# ── Run all phases ────────────────────────────────────────────────────
phase_env
echo ""
echo "CLAUDE.md Mapping Validation"
echo "============================="
phase_mappings
echo ""
echo "Config Size Audit"
echo "================="
phase_sizes
echo ""
echo "=== Skill Token/Line Audit ==="
echo "Limits: SKILL.md <= 500 lines, description <= 100 words"
echo ""
phase_skill_tokens
echo ""
echo "=== ctx.yaml Cache Audit ==="
phase_ctx_audit
echo ""
echo "=== R-universe Build Status ==="
phase_r_universe

exit 0
