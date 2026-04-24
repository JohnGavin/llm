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
  if [ "${IN_NIX_SHELL:-}" = "impure" ] || [ "${IN_NIX_SHELL:-}" = "pure" ] || [ "${IN_NIX_SHELL:-}" = "1" ]; then
    echo "Nix Shell: active (${IN_NIX_SHELL:-})"
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

  # Count statuses (avoid pipe subshell — background jobs die in subshells)
  local n_ok=0 n_stale=0 n_missing=0 n_other=0 missing_list=""
  while IFS=: read -r status pkg; do
    case "$status" in
      OK) n_ok=$((n_ok + 1)) ;;
      STALE) n_stale=$((n_stale + 1)) ;;
      OTHER_VER) n_other=$((n_other + 1)) ;;
      MISSING) n_missing=$((n_missing + 1)); missing_list="$missing_list $pkg" ;;
    esac
  done <<< "$audit_output"

  echo "ctx cache: $n_ok OK, $n_stale stale, $n_other wrong-version, $n_missing missing"
  [ "$n_missing" -gt 0 ] && echo "  Missing:$missing_list"

  # Auto-launch background ctx_sync (OUTSIDE pipe — survives hook exit)
  if [ "$((n_missing + n_stale + n_other))" -gt 0 ] && [ -f "DESCRIPTION" ]; then
    echo "  Launching background ctx_sync..."
    nohup timeout 600 Rscript -e 'source("~/docs_gh/llm/R/tar_plans/plan_pkgctx.R"); ctx_sync("DESCRIPTION")' \
      > /tmp/ctx_sync_$$.log 2>&1 &
    echo "  Background PID $! — log at /tmp/ctx_sync_$$.log"
  fi
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

# ── Phase 7: Worktree Context + Stale Worktrees ─────────────────────
phase_worktrees() {
  # 7a: Detect if THIS session is inside a worktree
  local git_dir common_dir
  git_dir=$(git rev-parse --git-dir 2>/dev/null) || true
  common_dir=$(git rev-parse --git-common-dir 2>/dev/null) || true

  if [ -n "$git_dir" ] && [ -n "$common_dir" ] && [ "$git_dir" != "$common_dir" ]; then
    # We are inside a worktree (git-dir != git-common-dir)
    local branch wt_path main_path
    branch=$(git branch --show-current 2>/dev/null || echo "detached")
    wt_path=$(pwd)
    main_path=$(cd "$common_dir/.." 2>/dev/null && pwd)
    echo "WORKTREE SESSION: branch=$branch path=$wt_path (main=$main_path)"

    # 7b: Warn about _targets/ store isolation
    if [ -d "_targets" ]; then
      echo "  WARN: _targets/ store exists in worktree — may conflict with main."
      echo "  Fix: tar_config_set(store = '_targets_${branch}') in this worktree"
    fi
    if [ -d "$main_path/_targets" ]; then
      echo "  INFO: Main repo has _targets/ — do NOT run tar_make() in both simultaneously"
    fi
  fi

  # 7c: Scan for stale worktrees (both .claude/worktrees and git worktree list)
  local wt_count=0

  # Agent worktrees (.claude/worktrees/)
  local wt_dir=".claude/worktrees"
  if [ -d "$wt_dir" ]; then
    local total_mb=0
    for d in "$wt_dir"/*/; do
      [ -d "$d" ] || continue
      wt_count=$((wt_count + 1))
      local size_kb
      size_kb=$(du -sk "$d" 2>/dev/null | cut -f1)
      local size_mb=$(( (size_kb + 512) / 1024 ))
      total_mb=$((total_mb + size_mb))
    done
    [ "$wt_count" -gt 0 ] && echo "Agent worktrees: $wt_count dirs, ${total_mb}MB (safe-deletion rule applies)"
  fi

  # Git worktrees (git worktree list)
  local git_wt_count=0
  while IFS= read -r line; do
    # Skip the main worktree (first line)
    git_wt_count=$((git_wt_count + 1))
    [ "$git_wt_count" -le 1 ] && continue
    local wt_branch
    wt_branch=$(echo "$line" | sed 's/.*\[//' | sed 's/\]//')
    local wt_loc
    wt_loc=$(echo "$line" | cut -d' ' -f1)
    echo "  Git worktree: $wt_branch at $wt_loc"
    wt_count=$((wt_count + 1))
  done < <(git worktree list 2>/dev/null || true)

  # 7d: Scan for convention-named sibling worktree dirs
  local repo_name parent_dir
  repo_name=$(basename "$(pwd)")
  parent_dir=$(dirname "$(pwd)")
  for suffix in sonnet haiku; do
    local sibling="$parent_dir/${repo_name}-${suffix}"
    if [ -d "$sibling" ]; then
      local sib_kb sib_mb sib_age
      sib_kb=$(du -sk "$sibling" 2>/dev/null | cut -f1)
      sib_mb=$(( (sib_kb + 512) / 1024 ))
      # Age: newest file modification
      sib_age=$(find "$sibling" -maxdepth 2 -type f -newer "$sibling/.git" 2>/dev/null | head -1)
      echo "  Sibling worktree: ${repo_name}-${suffix} (${sib_mb}MB)"
      [ -z "$sib_age" ] && echo "    No recent changes — candidate for cleanup"
      wt_count=$((wt_count + 1))
    fi
  done
  # Also check for feat-*/fix-* pattern
  for sibling in "$parent_dir/${repo_name}"-feat-* "$parent_dir/${repo_name}"-fix-*; do
    [ -d "$sibling" ] || continue
    local sib_name sib_kb sib_mb
    sib_name=$(basename "$sibling")
    sib_kb=$(du -sk "$sibling" 2>/dev/null | cut -f1)
    sib_mb=$(( (sib_kb + 512) / 1024 ))
    echo "  Sibling worktree: $sib_name (${sib_mb}MB)"
    wt_count=$((wt_count + 1))
  done

  # 7e: Check for prunable worktrees (registered but dir missing)
  local prunable
  prunable=$(git worktree list --porcelain 2>/dev/null | grep -c "^prunable" || echo 0)
  [ "$prunable" -gt 0 ] && echo "  Prunable worktrees: $prunable (run: git worktree prune)"

  [ "$wt_count" -eq 0 ] && echo "No worktrees found"
}

# ── Phase 8: roborev Review Status ────────────────────────────────────
phase_roborev() {
  if ! command -v /usr/local/bin/roborev >/dev/null 2>&1; then
    echo "roborev: not installed"
    return
  fi
  # Capture full output first, THEN truncate (avoids SIGPIPE from head)
  local status
  status=$(/usr/local/bin/roborev status 2>/dev/null) || true
  if echo "$status" | grep -q "not running\|connection refused" 2>/dev/null; then
    echo "roborev: daemon not running"
    return
  fi
  echo "$status" | grep -E "Jobs:|Daemon:|Recent Errors" | head -3 || true
  local failed
  failed=$(/usr/local/bin/roborev list --status failed --limit 5 2>/dev/null) || true
  if [ -n "$failed" ]; then
    echo "Failed reviews:"
    echo "$failed" | head -6
    echo "Fix with: /roborev-fix or roborev refine"
  fi
}

# ── Phase 9: Weekly Burn Rate ─────────────────────────────────────────
phase_burn_rate() {
  local script="$HOME/.claude/scripts/burn_rate_check.sh"
  if [ -x "$script" ]; then
    timeout 45 "$script" full 2>/dev/null || echo "Burn rate: check failed"
  fi
}

# ── Run all phases (compact output: pass=checkmark, warn/fail=detail) ──
WARNINGS=""

# Phase 1: Nix
phase_env_result=$(phase_env 2>/tmp/phase_env_err.log | head -1)
echo "$phase_env_result" | grep -qi "active" && nix_ok="Y" || nix_ok="N"

# Phase 2: Mappings (capture warnings)
map_output=$(phase_mappings 2>/dev/null)
if echo "$map_output" | grep -qiE "mismatch|WARN"; then
  WARNINGS="${WARNINGS}$(echo "$map_output" | grep -iE 'WARN|MISMATCH') "
fi

# Phase 3: Sizes (capture warnings)
size_output=$(phase_sizes 2>/dev/null)
if echo "$size_output" | grep -qiE "WARN|FAIL"; then
  WARNINGS="${WARNINGS}$(echo "$size_output" | grep -iE 'WARN|FAIL') "
fi

# Phase 4: Skill tokens
skill_output=$(phase_skill_tokens 2>/dev/null)
if echo "$skill_output" | grep -qiE "WARNING|OVER"; then
  WARNINGS="${WARNINGS}$(echo "$skill_output" | grep -iE 'WARNING|OVER') "
fi
n_skills=$(echo "$skill_output" | grep -oE '[0-9]+ skills' | head -1)

# Phase 5+6: ctx + R-universe (single Rscript)
r_output=$(timeout 15 Rscript -e '
  if (file.exists("DESCRIPTION")) {
    tryCatch({
      d <- read.dcf("DESCRIPTION", fields = c("Imports","Suggests","Depends"))
      raw <- paste(na.omit(as.character(d)), collapse = ",")
      p <- trimws(unlist(strsplit(raw, ",")))
      p <- sub("\\s*\\(.*", "", p)
      base_pkgs <- c("base","compiler","datasets","graphics","grDevices","grid",
        "methods","parallel","splines","stats","stats4","tcltk","tools","utils")
      p <- p[nzchar(p) & !p %in% c("R", base_pkgs)]
      cache <- file.path(Sys.getenv("HOME"), "docs_gh/proj/data/llm/content/inst/ctx/external")
      n_ok <- 0L; n_other <- 0L; n_miss <- 0L
      for (pkg in sort(unique(p))) {
        ver <- tryCatch(as.character(packageVersion(pkg)), error = function(e) "unknown")
        f <- file.path(cache, paste0(pkg, "@", ver, ".ctx.yaml"))
        if (file.exists(f)) {
          age <- as.numeric(difftime(Sys.time(), file.mtime(f), units = "days"))
          if (age > 30) n_other <- n_other + 1L else n_ok <- n_ok + 1L
        } else {
          any_ver <- list.files(cache, pattern = paste0("^", gsub("\\.", "\\\\.", pkg), "@"))
          if (length(any_ver) > 0) n_other <- n_other + 1L
          else n_miss <- n_miss + 1L
        }
      }
      cat(sprintf("ctx:%d/%d/%d", n_ok, n_other, n_miss))
    }, error = function(e) cat("ctx:err"))
  } else { cat("ctx:nodesc") }
  cat("|")
  tryCatch({
    resp <- readLines("https://johngavin.r-universe.dev/api/packages", warn = FALSE)
    d <- jsonlite::fromJSON(paste(resp, collapse = ""))
    if (is.data.frame(d) && nrow(d) > 0) {
      fails <- d[d[["_status"]] != "success", , drop = FALSE]
      cat(sprintf("runiverse:%d/%d", sum(d[["_status"]] == "success"), nrow(fails)))
      if (nrow(fails) > 0) cat(sprintf("(%s)", paste(fails$Package, collapse = ",")))
    }
  }, error = function(e) cat("runiverse:err"))
' 2>/dev/null) || r_output="R:timeout"

# Parse R output
ctx_part=$(echo "$r_output" | cut -d'|' -f1)
runiverse_part=$(echo "$r_output" | cut -d'|' -f2)

# Phase 7: Worktrees (detect context + stale)
wt_output=$(phase_worktrees 2>/dev/null) || true
wt_count=0
is_worktree="N"
if echo "$wt_output" | grep -q "WORKTREE SESSION"; then
  is_worktree="Y"
  # Show full worktree context to user
  echo "$wt_output" | grep -E "WORKTREE|WARN|INFO|Fix" || true
fi
if echo "$wt_output" | grep -qE "Agent worktrees|Git worktree:|Sibling worktree:|Prunable"; then
  # Show worktree details
  echo "$wt_output" | grep -E "Sibling|Prunable|Agent|Git worktree|cleanup" || true
  wt_count=$(echo "$wt_output" | grep -cE "worktree:|Prunable" || echo 0)
fi

# Phase 8: roborev
roborev_status=""
if command -v /usr/local/bin/roborev >/dev/null 2>&1; then
  rv_output=$(/usr/local/bin/roborev status 2>/dev/null) || true
  if echo "$rv_output" | grep -qE "running" 2>/dev/null; then
    n_failed=$(/usr/local/bin/roborev list --status failed --limit 1 2>/dev/null | grep -cE "^Job" || true) || true
    [ "${n_failed:-0}" -gt 0 ] && roborev_status="roborev:${n_failed}failed" || roborev_status="roborev:ok"
  else
    roborev_status="roborev:off"
  fi
fi

# Phase 9: Burn rate (run in background, use cache if available)
burn_output=""
burn_script="$HOME/.claude/scripts/burn_rate_check.sh"
if [ -x "$burn_script" ]; then
  burn_output=$(timeout 45 "$burn_script" compact 2>/dev/null) || burn_output="burn:err"
fi

# Phase 10: Kill orphan crew workers (no controller running)
orphan_count=0
if /bin/ps -eo pid,etime,command 2>/dev/null | grep -q "crew_worker"; then
  # Check if any tar_make controller is running
  if ! /bin/ps -eo command 2>/dev/null | grep -qE "tar_make|targets::tar_make"; then
    # No controller — all crew workers are orphans
    orphan_pids=$(/bin/ps -eo pid,command 2>/dev/null | grep "crew_worker" | grep -v grep | awk '{print $1}')
    orphan_count=$(echo "$orphan_pids" | grep -c '[0-9]' || echo 0)
    if [ "$orphan_count" -gt 0 ]; then
      echo "$orphan_pids" | xargs kill 2>/dev/null || true
      WARNINGS="${WARNINGS}Killed ${orphan_count} orphan crew workers "
    fi
  fi
fi

# Phase 11: AGENTS.md audit
audit_output=""
audit_script="$HOME/.claude/scripts/agents_md_audit.sh"
if [ -x "$audit_script" ]; then
  audit_output=$("$audit_script" 2>/dev/null) || true
  if echo "$audit_output" | grep -q "DRIFT"; then
    WARNINGS="${WARNINGS}${audit_output} "
  fi
fi

# ── Phase 12: Log session start to unified DuckDB ──
_log_script="$HOME/.claude/scripts/log_session.sh"
_session_id="${CLAUDE_SESSION_ID:-$(uuidgen 2>/dev/null || echo unknown)}"
if [ -x "$_log_script" ]; then
  "$_log_script" start "$_session_id" "$(basename "$(pwd)")" "" 2>/dev/null || true
fi

# ── Phase 13: Surface unprocessed braindumps for Claude to act on ──
_bd_db="$HOME/.claude/logs/unified.duckdb"
if [ -f "$_bd_db" ]; then
  _bd_output=$(duckdb "$_bd_db" -c "
    SELECT id, source, captured_at::VARCHAR as captured,
           CASE WHEN LENGTH(raw_text) > 120 THEN SUBSTR(raw_text, 1, 120) || '...' ELSE raw_text END as preview
    FROM braindumps
    WHERE processed_prompt IS NULL
    ORDER BY captured_at DESC;
  " 2>/dev/null | grep "│" | grep -v "int32\|varchar\|─") || true

  _bd_count=$(duckdb "$_bd_db" -c "SELECT COUNT(*) FROM braindumps WHERE processed_prompt IS NULL;" 2>/dev/null | grep -oE '[0-9]+' | tail -1) || _bd_count=0

  if [ "${_bd_count:-0}" -gt 0 ]; then
    echo ""
    echo "ACTION: $_bd_count unprocessed braindump(s) awaiting interpretation:"
    echo "$_bd_output"
    echo ""
    echo "For each braindump: interpret the instruction, decide what action to take"
    echo "(create issue, run command, update file, etc.), then mark as processed:"
    echo "  duckdb ~/.claude/logs/unified.duckdb -c \"UPDATE braindumps SET processed_prompt='<summary>', processed_at=current_timestamp WHERE id=<N>;\""
  fi

  # Also check for actions without linked issues (stale)
  _stale=$(duckdb "$_bd_db" -c "
    SELECT COUNT(*) FROM braindump_actions
    WHERE status='created' AND issue_closed_at IS NULL
    AND created_at < current_timestamp - INTERVAL 14 DAY;
  " 2>/dev/null | grep -oE '[0-9]+' | tail -1 2>/dev/null) || _stale=0
  [ "${_stale:-0}" -gt 0 ] && echo "STALE: $_stale braindump-linked issues open >14 days"
fi

# ── Compact summary line ──
summary=""
[ "$nix_ok" = "Y" ] && summary="nix:ok" || summary="nix:MISSING"
summary="$summary | config:ok | ${n_skills:-skills:?} | $ctx_part | $runiverse_part"
[ "$is_worktree" = "Y" ] && summary="$summary | worktree:active"
[ "$wt_count" -gt 0 ] && summary="$summary | worktrees:${wt_count}"
[ -n "$roborev_status" ] && summary="$summary | $roborev_status"
[ -n "$burn_output" ] && summary="$summary | $burn_output"
echo "$summary"

# Show warnings (only if any)
if [ -n "$WARNINGS" ]; then
  echo "WARN: $(echo "$WARNINGS" | tr '\n' ' ' | sed 's/  */ /g' | head -c 200)"
fi

# Burn-rate-aware worktree suggestion
if echo "${burn_output:-}" | grep -qE "CRITICAL|WARN"; then
  if [ "$is_worktree" = "N" ]; then
    _repo_name=$(basename "$(pwd)")
    echo ""
    echo "TIP: Budget pressure detected. To continue work at lower cost:"
    echo "  git worktree add ../${_repo_name}-sonnet feat/current-task"
    echo "  cd ../${_repo_name}-sonnet && claude --model sonnet"
  fi
fi

# Background ctx_sync if missing packages detected
if [ -f "DESCRIPTION" ]; then
  ctx_miss=$(echo "$ctx_part" | cut -d: -f2 | cut -d/ -f3)
  if [ "${ctx_miss:-0}" -gt 0 ]; then
    nohup timeout 600 Rscript -e 'source("~/docs_gh/llm/R/tar_plans/plan_pkgctx.R"); ctx_sync("DESCRIPTION")' \
      > /tmp/ctx_sync_$$.log 2>&1 &
    echo "ctx_sync: $ctx_miss missing, generating in background (PID $!)"
  fi
fi

exit 0
