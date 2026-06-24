#!/usr/bin/env bash
# session_init.sh - Unified session start checks
# Merges: startup_check.sh, validate_claude_md.sh, config_size_check.sh, count_skill_tokens.sh
# Hook: SessionStart

set -euo pipefail

CLAUDE_RUNTIME_ROOT="${CLAUDE_RUNTIME_ROOT:-$HOME/.claude}"
CLAUDE_CONTROL_PLANE_ROOT="${CLAUDE_CONTROL_PLANE_ROOT:-$CLAUDE_RUNTIME_ROOT}"
CLAUDE_DIR="$CLAUDE_CONTROL_PLANE_ROOT"
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

as_int_or_zero() {
  local value="${1:-0}"
  value=$(printf '%s\n' "$value" | grep -E '^[0-9]+$' | head -1 || true)
  printf '%s\n' "${value:-0}"
}

# ── Phase 1b: Permission Mode Advisory ────────────────────────────────
# Detects workspace kind (main / worktree / scratch) and reports the
# expected --permission-mode. Warns if settings.json defaultMode
# disagrees with the workspace expectation.
# See rule: permission-mode-discipline
phase_perm_mode() {
  local kind expected current settings
  case "$PWD" in
    /tmp|/tmp/*|/private/tmp|/private/tmp/*) kind="scratch" ;;
    *)
      local common gitdir
      common=$(git rev-parse --git-common-dir 2>/dev/null || echo "")
      gitdir=$(git rev-parse --git-dir 2>/dev/null || echo "")
      if [ -n "$common" ] && [ -n "$gitdir" ]; then
        common=$(cd "$common" 2>/dev/null && pwd) || common=""
        gitdir=$(cd "$gitdir" 2>/dev/null && pwd) || gitdir=""
        if [ -n "$common" ] && [ "$common" != "$gitdir" ]; then
          kind="worktree"
        else
          kind="main"
        fi
      else
        kind="other"
      fi
      ;;
  esac
  case "$kind" in
    scratch|worktree) expected="bypassPermissions" ;;
    main)             expected="default" ;;
    *)                expected="default" ;;
  esac
  settings="$SETTINGS_JSON"
  current="unknown"
  if [ -f "$settings" ]; then
    current=$(grep -oE '"defaultMode"[[:space:]]*:[[:space:]]*"[^"]+"' "$settings" \
              | head -1 | sed -E 's/.*"([^"]+)"[[:space:]]*$/\1/')
    [ -z "$current" ] && current="unknown"
  fi
  if [ "$current" = "$expected" ]; then
    echo "Permission Mode: ok ($kind → $expected)"
  elif [ "$kind" = "worktree" ] || [ "$kind" = "scratch" ]; then
    # Worktree/scratch running in 'default' mode — provide concrete relaunch hint.
    # Detect whether cc.sh was used (it exports CC_LAUNCHED_VIA_WRAPPER=1 before exec).
    if [ "${CC_LAUNCHED_VIA_WRAPPER:-0}" = "1" ]; then
      # cc.sh was used but settings.json still says 'default' (static field — harmless
      # false-positive; runtime permission mode is correctly bypassPermissions).
      echo "Permission Mode: ok ($kind → $expected via cc.sh; settings.json defaultMode is static)"
    else
      echo "Permission Mode: WARN workspace=$kind expected=$expected actual=$current"
      echo "  → Relaunch via: ~/.claude/scripts/cc.sh (sets --permission-mode bypassPermissions)"
      echo "  → Or set CLAUDE_ALLOW_DEFAULT_IN_WORKTREE=1 to suppress (not recommended)"
      echo "  → See permission-discipline rule Part 1"
    fi
  else
    echo "Permission Mode: WARN workspace=$kind expected=$expected actual=$current — see permission-discipline rule"
  fi
}

# ── Phase 1c: Project Environment Class ──────────────────────────────
# Reads $PWD/.claude/CLAUDE.md for an Environment: field.
# Reports the value and warns if prod.
# See rule: prod-staging-context-guard
phase_env_class() {
  local project_claude="$PWD/.claude/CLAUDE.md"
  local env_val=""
  if [ -f "$project_claude" ]; then
    env_val=$(grep -iE '^Environment:[[:space:]]*(research|dev|prod|mixed)' "$project_claude" \
              | head -1 | sed -E 's/^[Ee]nvironment:[[:space:]]*//' | tr -d '`' | xargs)
  fi
  if [ -z "$env_val" ]; then
    echo "Environment: unspecified (defaulting to research)"
  elif [ "$env_val" = "prod" ]; then
    echo "Environment: WARN prod — live service; destructive ops carry extra risk"
  else
    echo "Environment: $env_val"
  fi
}

# ── Phase 1d: Cross-Project Scope Authority ──────────────────────────
# Reads $PWD/.claude/CLAUDE.md for "Cross-project authority" row.
# Reports whether this session may work outside its own tree.
# See rule: cross-project-scope (llm#190)
phase_scope() {
  local project_claude="$PWD/.claude/CLAUDE.md"
  local scope_val=""
  if [ -f "$project_claude" ]; then
    scope_val=$(grep -iE 'Cross-project authority' "$project_claude" \
                | head -1 | grep -oiE '(true|false)' | head -1)
  fi
  if [ "${scope_val:-false}" = "true" ]; then
    echo "project-scope: cross-project=YES"
  else
    echo "project-scope: own-tree-only"
  fi
}

# ── Phase 1e: Worktree-Parent CWD Detection (advisory) ───────────────
# Detects when cwd is under a worktree-parent dir (~/docs_gh/worktrees/
# canonical per llm#582, ~/worktrees/ legacy) but is NOT itself a git
# worktree (only contains worktree subdirs). Lists active worktrees so the
# user can cd into one, or back to the canonical main checkout.
# See rule: worktree-location
phase_worktree_parent() {
  local cwd
  cwd=$(pwd 2>/dev/null) || return 0
  case "$cwd" in
    "$HOME/docs_gh/worktrees"/*|"$HOME/worktrees"/*) : ;;
    *) return 0 ;;
  esac
  # If we're in an actual git repo / worktree, Phase 7 handles it.
  if git rev-parse --git-dir >/dev/null 2>&1; then
    return 0
  fi
  # Find candidate worktrees 1-2 levels under cwd (.git can be a dir or file).
  local found_any=0
  local candidates=""
  while IFS= read -r d; do
    [ -e "$d/.git" ] || continue
    candidates="${candidates}    - ${d#$cwd/}\n"
    found_any=1
  done < <(find "$cwd" -mindepth 1 -maxdepth 2 -type d 2>/dev/null)
  if [ "$found_any" -eq 0 ]; then
    echo "WORKTREE-PARENT: cwd is a worktree-parent dir but no active worktrees found here."
    echo "  Try: cd ~/docs_gh/<project>/  (canonical main checkout)"
    return 0
  fi
  echo "WORKTREE-PARENT: cwd is a worktree parent dir, not a worktree itself."
  echo "  Active worktrees here:"
  printf "$candidates"
  local proj
  proj=$(basename "$cwd")
  if [ -d "$HOME/docs_gh/$proj" ]; then
    echo "  Either: cd into one of the worktrees listed above"
    echo "      or: cd ~/docs_gh/$proj  (canonical main checkout)"
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

  # Guard: nix-shell must be available; sessions outside Nix shell would silently
  # time out (old R:timeout banner). Fail explicitly instead (#562).
  if ! command -v nix-shell >/dev/null 2>&1; then
    echo "ctx audit: WARN nix-shell missing — skipped"
    return
  fi

  local _llm_nix="$HOME/docs_gh/llm/default.nix"

  # Use R to parse DESCRIPTION and check version-stamped ctx files.
  # R code written to a temp file to avoid quoting complexity with nix-shell --run (#562).
  # Output: one line per package as "STATUS:pkg" (OK, STALE, MISSING)
  local _audit_r
  _audit_r=$(mktemp /tmp/ctx_audit_XXXXXX.R)
  cat > "$_audit_r" << 'REOF'
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
        any_ver <- list.files(cache, pattern = paste0("^", gsub("\\.", "\\\\.", pkg), "@"), full.names = TRUE)
        if (length(any_ver) > 0) cat(paste0("OTHER_VER:", pkg), "\n")
        else cat(paste0("MISSING:", pkg), "\n")
      }
    }
REOF

  # Foreground audit: timeout bumped 10->30s to accommodate nix-shell entry cost (#562)
  local audit_output
  audit_output=$(timeout 30 nix-shell "$_llm_nix" --run "Rscript '$_audit_r'" 2>/dev/null) || true
  rm -f "$_audit_r"
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
  # Wrapped in nix-shell so it works regardless of whether the session entered Nix (#562)
  if [ "$((n_missing + n_stale + n_other))" -gt 0 ] && [ -f "DESCRIPTION" ]; then
    echo "  Launching background ctx_sync..."
    nohup timeout 600 nix-shell "$_llm_nix" --run \
      "Rscript -e 'source(\"~/docs_gh/llm/R/tar_plans/plan_pkgctx.R\"); ctx_sync(\"DESCRIPTION\")'" \
      > /tmp/ctx_sync_$$.log 2>&1 &
    echo "  Background PID $! — log at /tmp/ctx_sync_$$.log"
  fi

  # Auto-launch background local_ctx_sync — ingests sibling-project ctx.yaml files (#207)
  # Wrapped in nix-shell so it works regardless of whether the session entered Nix (#562)
  nohup timeout 120 nix-shell "$_llm_nix" --run \
    "Rscript -e 'source(\"~/docs_gh/llm/R/tar_plans/plan_pkgctx.R\"); local_ctx_sync(dry_run = FALSE)'" \
    > /tmp/local_ctx_sync_$$.log 2>&1 &
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

  # 7f: Auto-GC stale agent worktrees (current project only, conservative 14d threshold)
  # Acceptance criteria: llm#424 Part C
  # Skip entirely if disabled; never exits non-zero (fail-open).
  if [ "${CLAUDE_SESSION_INIT_WORKTREE_GC:-1}" != "0" ]; then
    local _gc_log="${HOME}/.claude/logs/session_init_worktree_gc.log"
    local _gc_proj_root
    _gc_proj_root=$(git rev-parse --show-toplevel 2>/dev/null) || true
    local _gc_git_common
    _gc_git_common=$(git rev-parse --git-common-dir 2>/dev/null) || true
    case "${_gc_git_common:-}" in /*) : ;; *) _gc_git_common="${_gc_proj_root}/${_gc_git_common}" ;; esac
    local _gc_agent_dir="${_gc_proj_root}/.claude/worktrees"
    local _gc_now
    _gc_now=$(date +%s 2>/dev/null) || _gc_now=0
    local _gc_threshold=$(( 14 * 86400 ))  # 14 days in seconds
    local _gc_removed=0
    local _gc_cwd
    _gc_cwd=$(pwd 2>/dev/null) || true

    if [ -d "${_gc_agent_dir:-}" ] && [ -n "${_gc_proj_root:-}" ] && [ -n "${_gc_git_common:-}" ]; then
      while IFS= read -r _gc_wt; do
        [ -d "$_gc_wt" ] || continue
        # Guard: never auto-remove current cwd or main checkout
        [ "$_gc_wt" = "$_gc_cwd" ] && continue
        [ "$_gc_wt" = "$_gc_proj_root" ] && continue
        local _gc_name
        _gc_name=$(basename "$_gc_wt")
        local _gc_meta="${_gc_git_common}/worktrees/${_gc_name}"
        [ -d "$_gc_meta" ] || continue
        # Age check: prefer locked file mtime, fall back to meta-dir mtime
        local _gc_mtime
        if [ -f "${_gc_meta}/locked" ]; then
          _gc_mtime=$(stat -f '%m' "${_gc_meta}/locked" 2>/dev/null) || _gc_mtime=0
        else
          _gc_mtime=$(stat -f '%m' "$_gc_meta" 2>/dev/null) || _gc_mtime=0
        fi
        local _gc_age=$(( _gc_now - _gc_mtime ))
        [ "$_gc_age" -lt "$_gc_threshold" ] && continue
        # PID check: only auto-remove if owner PID is confirmed dead
        local _gc_pid=""
        if [ -f "${_gc_meta}/locked" ]; then
          local _gc_lock_content
          _gc_lock_content=$(cat "${_gc_meta}/locked" 2>/dev/null) || true
          _gc_pid=$(printf '%s' "$_gc_lock_content" | grep -oE 'pid=[0-9]+' | grep -oE '[0-9]+' | head -n1 || true)
          [ -z "$_gc_pid" ] && _gc_pid=$(printf '%s' "$_gc_lock_content" | grep -oE '^[0-9]+$' | head -n1 || true)
          if [ -n "$_gc_pid" ] && kill -0 "$_gc_pid" 2>/dev/null; then
            continue  # owner alive — skip
          fi
        fi
        # Uncommitted-changes guard
        local _gc_status
        _gc_status=$(git -C "$_gc_wt" status --short 2>/dev/null) || true
        [ -n "$_gc_status" ] && continue
        # All guards passed — remove
        if git -C "$_gc_proj_root" worktree unlock "$_gc_wt" 2>/dev/null; then :; fi
        if git -C "$_gc_proj_root" worktree remove --force "$_gc_wt" 2>/dev/null; then
          _gc_removed=$(( _gc_removed + 1 ))
          mkdir -p "$(dirname "$_gc_log")"
          printf '%s REMOVED project=%s worktree=%s age=%ds\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$_gc_proj_root" "$_gc_wt" "$_gc_age" >> "$_gc_log"
        else
          mkdir -p "$(dirname "$_gc_log")"
          printf '%s REMOVE-FAILED project=%s worktree=%s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$_gc_proj_root" "$_gc_wt" >> "$_gc_log"
        fi
      done < <(find "$_gc_agent_dir" -maxdepth 1 -mindepth 1 -type d -name "agent-*" 2>/dev/null)
    fi
    [ "$_gc_removed" -gt 0 ] && echo "Worktree GC: removed ${_gc_removed} stale (>14d, PID-dead)"
  fi

  [ "$wt_count" -eq 0 ] && echo "No worktrees found"
}

# ── Phase 7g: Branch Harvest on Fork ──────────────────────────────────
# Scans unmerged feat/* branches for surface-touching commits and
# session-limit-interrupted markers. Silent on a clean repo. Advisory;
# triage outcomes are documented in the branch-harvest-on-fork rule.
# See: ~/docs_gh/llm/.claude/rules/branch-harvest-on-fork.md
phase_branch_harvest() {
  local script="${HOME}/.claude/scripts/branch_harvest_audit.sh"
  [ -x "$script" ] || return 0
  # 5s timeout, fail-open. Run in the current repo (default = $PWD).
  local out
  out=$(timeout 5 bash "$script" 2>/dev/null) || true
  [ -n "$out" ] && printf '%s\n' "$out"
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

  # Check for .roborev.toml when hook is enabled
  if [ -f "$PWD/.git/hooks/post-commit" ] && grep -q roborev "$PWD/.git/hooks/post-commit" 2>/dev/null; then
    if [ ! -f "$PWD/.roborev.toml" ]; then
      echo "WARN: roborev hook enabled but .roborev.toml missing"
      echo "  Create from: llm/.claude/templates/roborev-project-setup.md"
    fi
  fi

  # Show top-3 high-severity findings (actionable, not just counts)
  local high_findings
  high_findings=$(/usr/local/bin/roborev list --status failed --min-severity high --limit 3 2>/dev/null) || true
  if [ -n "$high_findings" ] && echo "$high_findings" | grep -q "^Job"; then
    echo "High-severity findings (fix these):"
    echo "$high_findings" | head -4
    echo "ACTION: Run /roborev-clear-backlog or roborev refine --min-severity high"
  fi

  local failed
  failed=$(/usr/local/bin/roborev list --status failed --limit 5 2>/dev/null) || true
  if [ -n "$failed" ]; then
    n_total=$(echo "$failed" | grep -c "^Job" || echo 0)
    [ "$n_total" -gt 0 ] && echo "Total failed reviews: $n_total"
  fi
}

# ── Phase 8b: roborev-autoclose visibility ────────────────────────────
# Reads ~/.claude/.roborev_autoclose_counters.json (written by F1 script).
# Emits one line: roborev-autoclose: threshold=<T> [closed_today=N, closed_week=M, parse_fail=P]
# Degrades gracefully when counter file is absent (F1 not yet merged).
# See llm#224 Phase 4 (F2 — visibility surfaces).
phase_roborev_autoclose() {
  local counter_file="${HOME}/.claude/.roborev_autoclose_counters.json"
  local repo_name
  repo_name=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo "unknown")")

  if [ ! -f "$counter_file" ]; then
    echo "roborev-autoclose: threshold=off (counter file absent — feature not yet active)"
    return
  fi

  # Pass values via env vars to avoid shell expansion of Python f-string braces
  # (unquoted heredoc << PYEOF would expand ${threshold} etc. as shell vars)
  ROBOREV_COUNTER_FILE="$counter_file" ROBOREV_REPO_NAME="$repo_name" python3 << 'PYEOF'
import json, sys, os
from datetime import datetime, timezone, timedelta

counter_file = os.environ.get("ROBOREV_COUNTER_FILE", "")
repo_name = os.environ.get("ROBOREV_REPO_NAME", "unknown")

try:
    with open(counter_file, "r") as f:
        data = json.load(f)
except Exception as e:
    print("roborev-autoclose: threshold=unknown (counter file unreadable: " + str(e) + ")")
    sys.exit(0)

by_date = data.get("by_date", {})
today_utc = datetime.now(timezone.utc).strftime("%Y-%m-%d")

# Last 7 days including today
week_dates = set()
for i in range(7):
    d = (datetime.now(timezone.utc) - timedelta(days=i)).strftime("%Y-%m-%d")
    week_dates.add(d)

# Effective threshold: most recent date entry that mentions this repo
threshold = "unknown"
for date_key in sorted(by_date.keys(), reverse=True):
    entry = by_date[date_key]
    t_obs = entry.get("threshold_observed", {})
    if repo_name in t_obs:
        threshold = t_obs[repo_name]
        break
    elif t_obs:
        # Fall back to any repo's threshold as global default
        threshold = next(iter(t_obs.values()))
        break

# closed_today for this repo
today_entry = by_date.get(today_utc, {})
today_by_repo = today_entry.get("by_repo", {})
if repo_name in today_by_repo:
    closed_today = int(today_by_repo[repo_name].get("closed", 0))
else:
    closed_today = int(today_entry.get("closed_count", 0))

parse_fail = int(today_entry.get("parse_fail_count", 0))

# closed_week across last 7 days
closed_week = 0
for d in week_dates:
    entry = by_date.get(d, {})
    by_repo = entry.get("by_repo", {})
    if repo_name in by_repo:
        closed_week += int(by_repo[repo_name].get("closed", 0))
    else:
        closed_week += int(entry.get("closed_count", 0))

print(f"roborev-autoclose: threshold={threshold} [closed_today={closed_today}, closed_week={closed_week}, parse_fail={parse_fail}]")
PYEOF
}

# ── Phase 9: Weekly Burn Rate ─────────────────────────────────────────
phase_burn_rate() {
  local script="$CLAUDE_DIR/scripts/burn_rate_check.sh"
  if [ -x "$script" ]; then
    timeout 45 "$script" full 2>/dev/null || echo "Burn rate: check failed"
  fi
}

# ── Run all phases (compact output: pass=checkmark, warn/fail=detail) ──
WARNINGS=""

# Phase 1: Nix
phase_env_result=$(phase_env 2>/tmp/phase_env_err.log | head -1)
echo "$phase_env_result" | grep -qi "active" && nix_ok="Y" || nix_ok="N"

# Phase 1b: Permission Mode
perm_output=$(phase_perm_mode 2>/dev/null)
if echo "$perm_output" | grep -q "WARN"; then
  WARNINGS="${WARNINGS}$(echo "$perm_output" | grep WARN) "
  perm_ok="N"
else
  perm_ok="Y"
fi

# Phase 1c: Project environment class
env_class_output=$(phase_env_class 2>/dev/null)
env_class_val="unspecified"
if echo "$env_class_output" | grep -qE 'Environment:[[:space:]]*(research|dev|mixed)'; then
  env_class_val=$(echo "$env_class_output" | grep -oE '(research|dev|mixed)' | head -1)
elif echo "$env_class_output" | grep -q "WARN prod"; then
  env_class_val="prod"
  WARNINGS="${WARNINGS}${env_class_output} "
fi

# Phase 1d: Cross-project scope (llm#190)
scope_output=$(phase_scope 2>/dev/null)
echo "$scope_output"

# Phase 1e: Worktree-parent cwd detection (advisory)
phase_worktree_parent 2>/dev/null || true

# Phase 2: Mappings (capture warnings)
map_output=$(phase_mappings 2>/dev/null)
if echo "$map_output" | grep -qiE "mismatch|WARN"; then
  WARNINGS="${WARNINGS}$(echo "$map_output" | grep -iE 'WARN|MISMATCH') "
fi

# Phase 3: Sizes — BACKGROUND (~0.35s; WARN/FAIL surfaced from cache)
_p3_cache="${HOME}/.claude/logs/session_init_phase3_cache.txt"
if [ -f "$_p3_cache" ]; then
  _p3_cached=$(cat "$_p3_cache" 2>/dev/null) || true
  if echo "$_p3_cached" | grep -qiE "WARN|FAIL"; then
    WARNINGS="${WARNINGS}$(echo "$_p3_cached" | grep -iE 'WARN|FAIL') "
  fi
fi
mkdir -p "$(dirname "$_p3_cache")"
nohup bash -c "
  CLAUDE_DIR='$CLAUDE_DIR'
  CLAUDE_MD='$CLAUDE_MD'
  SKILLS_DIR='$SKILLS_DIR'
  RULES_DIR='$RULES_DIR'
  AGENTS_DIR='$AGENTS_DIR'
  MEMORY_DIR='$MEMORY_DIR'
  $(declare -f phase_sizes)
  phase_sizes > '$_p3_cache' 2>/dev/null || true
" > /dev/null 2>&1 &

# Phase 4: Skill tokens — BACKGROUND (77 wc -l calls ~0.37s)
# Cache pattern: show cached skill count and warnings for summary line.
_p4_cache="${HOME}/.claude/logs/session_init_phase4_cache.txt"
n_skills=""
if [ -f "$_p4_cache" ]; then
  _p4_cached=$(cat "$_p4_cache" 2>/dev/null) || true
  n_skills=$(echo "$_p4_cached" | grep -oE '[0-9]+ skills' | head -1)
  if echo "$_p4_cached" | grep -qiE "WARNING|OVER"; then
    WARNINGS="${WARNINGS}$(echo "$_p4_cached" | grep -iE 'WARNING|OVER') "
  fi
fi
mkdir -p "$(dirname "$_p4_cache")"
nohup bash -c "
  CLAUDE_DIR='$CLAUDE_DIR'
  SKILLS_DIR='$SKILLS_DIR'
  $(declare -f phase_skill_tokens)
  phase_skill_tokens > '$_p4_cache' 2>/dev/null || true
" > /dev/null 2>&1 &

# Phase 5+6: ctx + R-universe — BACKGROUND REFRESH with cache.
# The live Rscript (R startup + network fetch) takes 5-15s on the critical path.
# We instead: (a) read last-run cache instantly, (b) launch background refresh.
# Cache file: ~/.claude/logs/session_init_phase56_cache.txt
_p56_cache="${HOME}/.claude/logs/session_init_phase56_cache.txt"
_p56_rscript='
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
'

# Read cached result (instant — one session stale, acceptable for advisory info)
r_output="ctx:cached|runiverse:cached"
if [ -f "$_p56_cache" ]; then
  r_output=$(cat "$_p56_cache" 2>/dev/null) || r_output="ctx:cached|runiverse:cached"
fi

# Launch background refresh — writes updated value to cache for next session
mkdir -p "$(dirname "$_p56_cache")"
nohup bash -c "timeout 20 Rscript -e '$_p56_rscript' 2>/dev/null > '$_p56_cache'.tmp && mv '$_p56_cache'.tmp '$_p56_cache'" \
  > /dev/null 2>&1 &

# Parse output (cached or live)
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

# Phase 7g: Branch Harvest on Fork — BACKGROUND (advisory, ~1.15s foreground cost)
# Output written to cache; shown at next session start if non-empty.
_bharvest_cache="${HOME}/.claude/logs/session_init_branch_harvest_cache.txt"
if [ -f "$_bharvest_cache" ]; then
  _bharvest_cached=$(cat "$_bharvest_cache" 2>/dev/null) || true
  [ -n "$_bharvest_cached" ] && printf '%s\n' "$_bharvest_cached"
fi
_bharvest_script="${HOME}/.claude/scripts/branch_harvest_audit.sh"
if [ -x "$_bharvest_script" ]; then
  mkdir -p "$(dirname "$_bharvest_cache")"
  nohup bash -c "timeout 5 bash '$_bharvest_script' 2>/dev/null > '$_bharvest_cache'.tmp && mv '$_bharvest_cache'.tmp '$_bharvest_cache' || true" \
    > /dev/null 2>&1 &
fi

# Phase 8: roborev — BACKGROUND (3 binary calls; each ~0.3-1s; total ~1-3s foreground cost)
# Show cached status instantly; refresh in background for next session.
_rv_cache="${HOME}/.claude/logs/session_init_roborev_cache.txt"
roborev_status=""
if [ -f "$_rv_cache" ]; then
  roborev_status=$(cat "$_rv_cache" 2>/dev/null) || roborev_status=""
fi

if command -v /usr/local/bin/roborev >/dev/null 2>&1; then
  # Check for missing .roborev.toml — this is fast (just file checks, no binary calls)
  if [ -f "$PWD/.git/hooks/post-commit" ] && grep -q roborev "$PWD/.git/hooks/post-commit" 2>/dev/null; then
    [ ! -f "$PWD/.roborev.toml" ] && WARNINGS="${WARNINGS}WARN: .roborev.toml missing "
  fi
  # Launch background refresh of roborev status
  mkdir -p "$(dirname "$_rv_cache")"
  nohup bash -c '
    rv_out=$(/usr/local/bin/roborev status 2>/dev/null) || true
    if echo "$rv_out" | grep -qE "running" 2>/dev/null; then
      n_high=$(/usr/local/bin/roborev list --status failed --min-severity high --limit 100 2>/dev/null | grep -cE "^Job" || true)
      n_total=$(/usr/local/bin/roborev list --status failed --limit 100 2>/dev/null | grep -cE "^Job" || true)
      n_high="${n_high:-0}"; n_total="${n_total:-0}"
      if [ "${n_high:-0}" -gt 0 ]; then
        echo "roborev:${n_high}high/${n_total}total"
      elif [ "${n_total:-0}" -gt 0 ]; then
        echo "roborev:${n_total}failed"
      else
        echo "roborev:ok"
      fi
    else
      echo "roborev:off"
    fi
  ' > "$_rv_cache" 2>/dev/null &
fi

# Phase 8b: roborev-autoclose visibility
phase_roborev_autoclose 2>/dev/null || echo "roborev-autoclose: threshold=unknown (error reading counter file)"

# Phase 9: Burn rate — CodexBar is now primary (#281 Phase 4c; closes llm#420).
# Soak log (2026-06-05 to 2026-06-16) confirmed CodexBar reliable (burn:78-86%)
# while ccusage/cmonitor-rs has been dead (BURN GUARD DEAD, 5+ consecutive runs).
# Legacy ccusage cross-check now OFF by default (dead weeks; saves one timeout 5).
# Set CLAUDE_BURN_RATE_COMPARE=1 explicitly to re-enable cross-check logging.
burn_output=""
burn_script="$CLAUDE_DIR/scripts/burn_rate_check.sh"
burn_cb_script="$CLAUDE_DIR/scripts/burn_rate_check_codexbar.sh"
if [ -x "$burn_cb_script" ]; then
  # CodexBar is primary (#281 Phase 4c)
  burn_output=$(timeout 5 "$burn_cb_script" 2>/dev/null) || burn_output="burn:err"
  if [ "${CLAUDE_BURN_RATE_COMPARE:-0}" = "1" ] && [ -x "$burn_script" ]; then
    burn_legacy=$(timeout 5 "$burn_script" compact 2>/dev/null) || burn_legacy="burn:err:legacy"
    _compare_log="${HOME}/.claude/logs/burn_rate_compare.log"
    printf '%s | primary=%s (codexbar) | legacy=%s (ccusage)\n' \
      "$(date '+%Y-%m-%dT%H:%M:%S')" \
      "${burn_output:-burn:err}" \
      "${burn_legacy:-burn:err}" \
      >> "$_compare_log" 2>/dev/null || true
    unset burn_legacy
  fi
elif [ -x "$burn_script" ]; then
  # CodexBar script absent — fall back to legacy ccusage
  burn_output=$(timeout 5 "$burn_script" compact 2>/dev/null) || burn_output="burn:err"
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

# Phase 11: AGENTS.md audit — BACKGROUND (~0.45s; DRIFT warnings shown from cache)
_agents_audit_cache="${HOME}/.claude/logs/session_init_agents_audit_cache.txt"
audit_script="$CLAUDE_DIR/scripts/agents_md_audit.sh"
if [ -f "$_agents_audit_cache" ]; then
  _agents_cached=$(cat "$_agents_audit_cache" 2>/dev/null) || true
  if echo "$_agents_cached" | grep -q "DRIFT"; then
    WARNINGS="${WARNINGS}${_agents_cached} "
  fi
fi
if [ -x "$audit_script" ]; then
  mkdir -p "$(dirname "$_agents_audit_cache")"
  nohup bash -c "'$audit_script' 2>/dev/null > '$_agents_audit_cache' || true" > /dev/null 2>&1 &
fi

# ── Phase 11b: Quarto post-render contrast wiring check ──
# Every Quarto project MUST wire the global dark-mode contrast audit into
# _quarto.yml post-render. See `dark-mode-completeness` rule.
if [ -f "_quarto.yml" ]; then
  _wiring='/Users/johngavin/docs_gh/llm/.claude/scripts/quarto_post_render_contrast.sh'
  if ! grep -q "$_wiring" "_quarto.yml" 2>/dev/null; then
    WARNINGS="${WARNINGS}WARN: _quarto.yml missing global dark-mode contrast wiring. Add to post-render: $_wiring "
  fi
fi

# ── Phase 11c: roborev post-commit hook coverage ──
# Scan known repos in roborev's DB for missing hooks. See JohnGavin/llm#148.
_rdb="$HOME/.roborev/reviews.db"
_sqlite=/usr/bin/sqlite3
if [ -f "$_rdb" ] && [ -x "$_sqlite" ]; then
  _missing_hooks=""
  while IFS= read -r _rp; do
    [ -z "$_rp" ] && continue
    [ -d "$_rp/.git" ] || [ -f "$_rp/.git" ] || continue
    _hp=$(/usr/bin/git -C "$_rp" config --get core.hooksPath 2>/dev/null || true)
    [ -z "$_hp" ] && _hp="$_rp/.git/hooks"
    _hook="$_hp/post-commit"
    if [ ! -f "$_hook" ] || ! /usr/bin/grep -q roborev "$_hook" 2>/dev/null; then
      _missing_hooks="${_missing_hooks}$(basename "$_rp") "
    fi
  done < <("$_sqlite" "$_rdb" "SELECT root_path FROM repos;" 2>/dev/null)
  if [ -n "$_missing_hooks" ]; then
    WARNINGS="${WARNINGS}WARN: roborev post-commit hook missing in: ${_missing_hooks}— run \`roborev install-hook\` inside each. "
  fi
fi

# ── Phase 11d: auto-rebootstrap unloaded launchd plists ──
# Detect known plists that have become unloaded and rebootstrap them.
# See JohnGavin/llm#148 sub-fix 3. Uses /bin/launchctl (not in nix-shell PATH).
_KNOWN_LABELS="com.roborev.auto-refine com.claude.roborev-autoclose com.claude.roborev-poll-merges com.claude.pr-status-pulse com.claude.wiki-health-pulse com.claude.config-pulse com.claude.knowledge-pulse"
_lc=/bin/launchctl
if [ -x "$_lc" ]; then
  _uid=$(/usr/bin/id -u)
  _rebooted=""
  for _label in $_KNOWN_LABELS; do
    _plist="$HOME/Library/LaunchAgents/$_label.plist"
    [ -f "$_plist" ] || continue
    if ! "$_lc" print "gui/$_uid/$_label" >/dev/null 2>&1; then
      if "$_lc" bootstrap "gui/$_uid" "$_plist" >/dev/null 2>&1; then
        _rebooted="${_rebooted}$_label "
      fi
    fi
  done
  if [ -n "$_rebooted" ]; then
    WARNINGS="${WARNINGS}INFO: re-bootstrapped unloaded plists: ${_rebooted}"
  fi
fi

# ── Phase 12: Log session start to unified DuckDB — BACKGROUND (~0.74s DuckDB cost) ──
_log_script="$CLAUDE_DIR/scripts/log_session.sh"
_session_id="${CLAUDE_SESSION_ID:-$(uuidgen 2>/dev/null || echo unknown)}"
if [ -x "$_log_script" ]; then
  nohup "$_log_script" start "$_session_id" "$(basename "$(pwd)")" "" > /dev/null 2>&1 &
fi
# Record session start time for session_stop braindump sweep (fast write, stay sync)
date '+%Y-%m-%d %H:%M:%S' > "$CLAUDE_RUNTIME_ROOT/logs/.session_start_time"

# ── Phase 13: Braindumps + dated issues — BACKGROUND (DuckDB/network; shown cached) ──
# Cache pattern: background job writes output; next session reads it instantly.
_p13_cache="${HOME}/.claude/logs/session_init_phase13_cache.txt"
if [ -f "$_p13_cache" ]; then
  _p13_cached=$(cat "$_p13_cache" 2>/dev/null) || true
  [ -n "$_p13_cached" ] && printf '\n%s\n' "$_p13_cached"
fi

# Background job: braindumps + dated issues + stale actions
_dated_url=$(/usr/bin/git config --get remote.origin.url 2>/dev/null || true)
_dated_repo_bg=""
if [ -n "$_dated_url" ]; then
  _dated_repo_bg=$(echo "$_dated_url" | /usr/bin/sed -E 's#^https?://[^/]+/##; s#^git@[^:]+:##; s#\.git$##')
  case "$_dated_repo_bg" in */*) : ;; *) _dated_repo_bg="" ;; esac
fi

mkdir -p "$(dirname "$_p13_cache")"
# Export vars needed by background subshell
_bg_db="${CLAUDE_RUNTIME_ROOT}/logs/unified.duckdb"
_bg_dated_repo="$_dated_repo_bg"
_bg_state_dir="${CLAUDE_RUNTIME_ROOT}/state/dated_issues_cache"
_bg_cache="$_p13_cache"

nohup bash -s "$_bg_db" "$_bg_dated_repo" "$_bg_state_dir" "$_bg_cache" > /dev/null 2>&1 <<'BGEOF' &
#!/usr/bin/env bash
_bd_db="$1"; _dated_repo="$2"; _dated_cache_dir="$3"; _out_cache="$4"
_output=""

# Braindumps
if [ -f "$_bd_db" ] && command -v duckdb >/dev/null 2>&1; then
  _bd_output=$(duckdb "$_bd_db" -c "
    SELECT id, source, captured_at::VARCHAR as captured,
           CASE WHEN LENGTH(raw_text) > 120 THEN SUBSTR(raw_text, 1, 120) || '...' ELSE raw_text END as preview
    FROM braindumps
    WHERE processed_prompt IS NULL
    ORDER BY captured_at DESC;
  " 2>/dev/null | grep "│" | grep -v "int32\|varchar\|─") || true
  _bd_count=$(duckdb -list -noheader "$_bd_db" -c "SELECT COUNT(*) FROM braindumps WHERE processed_prompt IS NULL;" 2>/dev/null | grep -oE '^[0-9]+$' | head -1) || _bd_count=0
  if [ "${_bd_count:-0}" -gt 0 ]; then
    _output="${_output}
ACTION: $_bd_count unprocessed braindump(s) awaiting interpretation:
$_bd_output

For each braindump: interpret the instruction, decide what action to take
(create issue, run command, update file, etc.), then mark as processed:
  duckdb ~/.claude/logs/unified.duckdb -c \"UPDATE braindumps SET processed_prompt='<summary>', processed_at=current_timestamp WHERE id=<N>;\""
  fi
  _stale=$(duckdb -list -noheader "$_bd_db" -c "
    SELECT COUNT(*) FROM braindump_actions
    WHERE status='created' AND issue_closed_at IS NULL
    AND created_at < current_timestamp - INTERVAL 14 DAY;
  " 2>/dev/null | grep -oE '^[0-9]+$' | head -1 2>/dev/null) || _stale=0
  [ "${_stale:-0}" -gt 0 ] && _output="${_output}
STALE: $_stale braindump-linked issues open >14 days"
fi

# Dated issues
if [ -n "$_dated_repo" ] && command -v gh >/dev/null 2>&1; then
  /bin/mkdir -p "$_dated_cache_dir" 2>/dev/null || true
  _dated_cache_file="$_dated_cache_dir/$(echo "$_dated_repo" | tr '/' '_').jsonl"
  _dated_mtime=0
  _dated_need_refresh=0
  if [ ! -f "$_dated_cache_file" ]; then
    _dated_need_refresh=1
  else
    _dated_mtime=$(/usr/bin/stat -f %m "$_dated_cache_file" 2>/dev/null || /usr/bin/stat -c %Y "$_dated_cache_file" 2>/dev/null || echo 0)
    _dated_now_sec=$(date +%s)
    [ "$((_dated_now_sec - _dated_mtime))" -gt 3600 ] && _dated_need_refresh=1
  fi
  if [ "$_dated_need_refresh" = "1" ]; then
    if timeout 5 gh issue list --repo "$_dated_repo" --state open --limit 100 \
        --json number,title \
        --jq '.[] | select(.title | test("^\\[[0-9]{4}-[0-9]{2}-[0-9]{2}\\]"))' \
        > "$_dated_cache_file.tmp" 2>/dev/null; then
      mv "$_dated_cache_file.tmp" "$_dated_cache_file" 2>/dev/null || true
    else
      rm -f "$_dated_cache_file.tmp" 2>/dev/null || true
    fi
  fi
  if [ -s "$_dated_cache_file" ] && [ -x /usr/bin/jq ]; then
    _dated_today_num=$(date +%Y%m%d)
    _dated_out=""
    while IFS= read -r _dated_line; do
      [ -z "$_dated_line" ] && continue
      _dated_title=$(printf '%s' "$_dated_line" | /usr/bin/jq -r '.title' 2>/dev/null) || _dated_title=""
      _dated_number=$(printf '%s' "$_dated_line" | /usr/bin/jq -r '.number' 2>/dev/null) || _dated_number=""
      [ -z "$_dated_title" ] && continue; [ -z "$_dated_number" ] && continue
      _dated_date=$(printf '%s' "$_dated_title" | /usr/bin/sed -nE 's/^\[([0-9]{4}-[0-9]{2}-[0-9]{2})\].*/\1/p')
      [ -z "$_dated_date" ] && continue
      _dated_date_num=$(echo "$_dated_date" | tr -d '-')
      if [ "$_dated_date_num" -le "$_dated_today_num" ] 2>/dev/null; then
        _dated_out="${_dated_out}DATED: ${_dated_repo}#${_dated_number} — ${_dated_title}
"
      fi
    done < "$_dated_cache_file"
    if [ -n "$_dated_out" ]; then
      _output="${_output}
=== Dated issues (≤ today) ===
${_dated_out}"
    fi
  fi
fi

# Write output to cache (empty string means nothing to show)
printf '%s' "$_output" > "$_out_cache" 2>/dev/null || true
BGEOF

# ── Phase 13b: Process pending skillify from previous session ──
if [ -f "${HOME}/.claude/.pending_skillify" ] && [ -x "${HOME}/.claude/scripts/process_pending_skillify.sh" ]; then
  nohup timeout 5 "${HOME}/.claude/scripts/process_pending_skillify.sh" > /dev/null 2>&1 &
fi

# ── Compact summary line ──
summary=""
[ "$nix_ok" = "Y" ] && summary="nix:ok" || summary="nix:MISSING"
[ "$perm_ok" = "Y" ] && summary="$summary | perm:ok" || summary="$summary | perm:WARN"
summary="$summary | env-class:${env_class_val} | config:ok | ${n_skills:-skills:?} | $ctx_part | $runiverse_part"
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
# Wrapped in nix-shell so it works regardless of whether the session entered Nix (#562)
if [ -f "DESCRIPTION" ]; then
  ctx_miss=$(echo "$ctx_part" | cut -d: -f2 | cut -d/ -f3)
  ctx_miss=$(as_int_or_zero "$ctx_miss")
  if [ "${ctx_miss:-0}" -gt 0 ]; then
    _llm_nix_bg="$HOME/docs_gh/llm/default.nix"
    nohup timeout 600 nix-shell "$_llm_nix_bg" --run \
      "Rscript -e 'source(\"~/docs_gh/llm/R/tar_plans/plan_pkgctx.R\"); ctx_sync(\"DESCRIPTION\")'" \
      > /tmp/ctx_sync_$$.log 2>&1 &
    echo "ctx_sync: $ctx_miss missing, generating in background (PID $!)"
  fi
fi

# ── Loop Status (Claude Code v2.1.72+) ────────────────────────────────
# Show active /loop and /schedule jobs at session start
# Note: /schedule list command only works within an active Claude session
# This phase documents the feature; actual list shown via /btw at runtime
echo ""
echo "TIP: Check active loops with: /btw 'Show running loops via /schedule list'"
echo "     Auto-loop suggestions: /loop 1h /check | /loop 30m /ctx-check"

# ── Phase 13d: roborev backlog banner (Component 6, JohnGavin/llm#163) ───────
# Surfaces open-count + top finding + addressed-rate for the current project.
# Format: roborev-backlog: open=N (priority-1=sev:cat, top=#id) | addressed=XX%
# Silent if DB missing or no project entry — graceful degradation.
phase_roborev_backlog() {
  local _rb_db="${HOME}/.roborev/reviews.db"
  local _rb_python="/usr/bin/python3"

  # Require python3 and DB — both must exist; silent skip otherwise
  [ -f "$_rb_db" ] || return 0
  [ -x "$_rb_python" ] || return 0

  # Derive project name from git toplevel (same logic as Phase 14)
  local _rb_root _rb_name
  _rb_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
  _rb_name=$(basename "$_rb_root")
  [ -n "$_rb_name" ] || return 0

  # Read top-finding from backlog.md if present (fast path — avoids re-querying DB)
  local _rb_backlog="${_rb_root}/.roborev/backlog.md"
  local _rb_top_sev="" _rb_top_cat="" _rb_top_id=""
  if [ -f "$_rb_backlog" ]; then
    # Extract first data row: | id | sev | category | ...
    local _rb_first_row
    _rb_first_row=$(grep -E '^\| [0-9]' "$_rb_backlog" | head -1) || true
    if [ -n "$_rb_first_row" ]; then
      _rb_top_id=$(echo "$_rb_first_row"  | awk -F'|' '{gsub(/ /,"",$2); print $2}')
      _rb_top_sev=$(echo "$_rb_first_row" | awk -F'|' '{gsub(/ /,"",$3); print $3}')
      _rb_top_cat=$(echo "$_rb_first_row" | awk -F'|' '{gsub(/ /,"",$4); print $4}')
    fi
  fi

  # Query DB for open count + addressed rate
  local _rb_out
  _rb_out=$("$_rb_python" - "$_rb_db" "$_rb_name" <<'PYEOF'
import sys, sqlite3

db_path   = sys.argv[1]
repo_name = sys.argv[2]

try:
    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
except Exception:
    sys.exit(0)

repo_row = con.execute(
    "SELECT id FROM repos WHERE name = ? ORDER BY id DESC LIMIT 1",
    (repo_name,)
).fetchone()

if repo_row is None:
    sys.exit(0)

repo_id = repo_row["id"]

try:
    stats = con.execute("""
        SELECT
            SUM(CASE WHEN rv.closed = 0 THEN 1 ELSE 0 END) AS open_count,
            COUNT(*) AS total_count,
            SUM(rv.closed) AS closed_count
        FROM reviews rv
        JOIN review_jobs rj ON rj.id = rv.job_id
        WHERE rj.repo_id = ?
          AND rj.status = 'done'
    """, (repo_id,)).fetchone()
except Exception:
    sys.exit(0)

con.close()

open_count   = stats["open_count"]  or 0
total_count  = stats["total_count"] or 0
closed_count = stats["closed_count"] or 0

addressed_pct = round(100.0 * closed_count / total_count) if total_count > 0 else 0
print(f"OPEN:{open_count}")
print(f"ADDRESSED:{addressed_pct}")
PYEOF
  ) || true

  [ -n "$_rb_out" ] || return 0

  local _rb_open _rb_pct
  _rb_open=$(printf '%s\n' "$_rb_out" | grep "^OPEN:"      | sed 's/^OPEN://')
  _rb_pct=$(printf  '%s\n' "$_rb_out" | grep "^ADDRESSED:" | sed 's/^ADDRESSED://')

  [ -n "$_rb_open" ] || return 0

  # Build the banner line
  local _rb_top_part=""
  if [ -n "$_rb_top_sev" ] && [ -n "$_rb_top_cat" ] && [ -n "$_rb_top_id" ]; then
    _rb_top_part=" (priority-1=${_rb_top_sev}:${_rb_top_cat}, top=#${_rb_top_id})"
  fi

  local _rb_pct_part=""
  [ -n "$_rb_pct" ] && _rb_pct_part=" | addressed=${_rb_pct}%"

  echo "roborev-backlog: open=${_rb_open}${_rb_top_part}${_rb_pct_part}"
}
# Phase 13d: roborev backlog — BACKGROUND (sqlite3 + python3 query)
# Show cached line instantly; refresh in background for next session.
_rbb_cache="${HOME}/.claude/logs/session_init_roborev_backlog_cache.txt"
if [ -f "$_rbb_cache" ]; then
  _rbb_cached=$(cat "$_rbb_cache" 2>/dev/null) || true
  [ -n "$_rbb_cached" ] && echo "$_rbb_cached"
fi
_rbb_db="${HOME}/.roborev/reviews.db"
_rbb_root=$(git rev-parse --show-toplevel 2>/dev/null) || true
_rbb_name=$(basename "${_rbb_root:-unknown}")
mkdir -p "$(dirname "$_rbb_cache")"
nohup bash -s "$_rbb_db" "$_rbb_name" "$_rbb_cache" > /dev/null 2>&1 <<'RBBEOF' &
#!/usr/bin/env bash
_rb_db="$1"; _rb_name="$2"; _rb_cache="$3"
[ -f "$_rb_db" ] || exit 0
[ -x /usr/bin/python3 ] || exit 0
_rb_backlog_file=$(dirname "$_rb_db")/../.roborev/backlog.md 2>/dev/null || true
_rb_top_sev=""; _rb_top_cat=""; _rb_top_id=""
# Find backlog.md relative to repo root (passed as name, need path)
_rb_root=$(git rev-parse --show-toplevel 2>/dev/null) || true
[ -n "$_rb_root" ] && _rb_backlog="$_rb_root/.roborev/backlog.md" || _rb_backlog=""
if [ -n "$_rb_backlog" ] && [ -f "$_rb_backlog" ]; then
  _rb_first_row=$(grep -E '^\| [0-9]' "$_rb_backlog" | head -1) || true
  if [ -n "$_rb_first_row" ]; then
    _rb_top_id=$(echo "$_rb_first_row"  | awk -F'|' '{gsub(/ /,"",$2); print $2}')
    _rb_top_sev=$(echo "$_rb_first_row" | awk -F'|' '{gsub(/ /,"",$3); print $3}')
    _rb_top_cat=$(echo "$_rb_first_row" | awk -F'|' '{gsub(/ /,"",$4); print $4}')
  fi
fi
_rb_out=$(/usr/bin/python3 - "$_rb_db" "$_rb_name" <<'PYEOF'
import sys, sqlite3
db_path = sys.argv[1]; repo_name = sys.argv[2]
try:
    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
except Exception:
    sys.exit(0)
repo_row = con.execute("SELECT id FROM repos WHERE name = ? ORDER BY id DESC LIMIT 1", (repo_name,)).fetchone()
if repo_row is None: sys.exit(0)
repo_id = repo_row["id"]
try:
    stats = con.execute("""
        SELECT SUM(CASE WHEN rv.closed = 0 THEN 1 ELSE 0 END) AS open_count,
               COUNT(*) AS total_count, SUM(rv.closed) AS closed_count
        FROM reviews rv JOIN review_jobs rj ON rj.id = rv.job_id
        WHERE rj.repo_id = ? AND rj.status = 'done'
    """, (repo_id,)).fetchone()
except Exception:
    sys.exit(0)
con.close()
open_count = stats["open_count"] or 0; total_count = stats["total_count"] or 0
closed_count = stats["closed_count"] or 0
addressed_pct = round(100.0 * closed_count / total_count) if total_count > 0 else 0
print(f"OPEN:{open_count}")
print(f"ADDRESSED:{addressed_pct}")
PYEOF
) || true
[ -n "$_rb_out" ] || exit 0
_rb_open=$(printf '%s\n' "$_rb_out" | grep "^OPEN:"      | sed 's/^OPEN://')
_rb_pct=$(printf  '%s\n' "$_rb_out" | grep "^ADDRESSED:" | sed 's/^ADDRESSED://')
[ -n "$_rb_open" ] || exit 0
_rb_top_part=""
[ -n "$_rb_top_sev" ] && [ -n "$_rb_top_cat" ] && [ -n "$_rb_top_id" ] && \
  _rb_top_part=" (priority-1=${_rb_top_sev}:${_rb_top_cat}, top=#${_rb_top_id})"
_rb_pct_part=""
[ -n "$_rb_pct" ] && _rb_pct_part=" | addressed=${_rb_pct}%"
echo "roborev-backlog: open=${_rb_open}${_rb_top_part}${_rb_pct_part}" > "$_rb_cache"
RBBEOF

# ── Phase 14a: T-lang flake.nix closure-rebuild advisory — BACKGROUND (~up to 5s) ──
# Output cached; advisory only (no action needed at prompt time).
_tlang_cache="${HOME}/.claude/logs/session_init_tlang_cache.txt"
if [ -f "$_tlang_cache" ]; then
  _tlang_cached=$(cat "$_tlang_cache" 2>/dev/null) || true
  [ -n "$_tlang_cached" ] && printf '\n%s\n' "$_tlang_cached"
fi
_tlang_check_script="$CLAUDE_DIR/scripts/check_tlang_flake_closure_rebuild.sh"
if [ -x "$_tlang_check_script" ]; then
  mkdir -p "$(dirname "$_tlang_cache")"
  nohup bash -c "
    _out=\$(timeout 5 bash '$_tlang_check_script' --quiet 2>/dev/null) || true
    if [ -n \"\$_out\" ]; then
      printf 'WARN: T-lang closure-rebuild marker missing in these projects:\n%s\n  Fix: cd <project> && bash default.post.sh\n  See: .claude/scripts/check_tlang_flake_closure_rebuild.sh\n' \"\$_out\" > '$_tlang_cache'
    else
      printf '' > '$_tlang_cache'
    fi
  " > /dev/null 2>&1 &
fi

# ── Phase 14b: Surface open ci-failure issues — BACKGROUND (gh network call ≤5s) ──
# Cache pattern: show cached line; refresh in background for next session.
# See JohnGavin/llm#387.
_cifail_cache="${HOME}/.claude/logs/session_init_cifail_cache.txt"
if [ -f "$_cifail_cache" ]; then
  _cifail_cached=$(cat "$_cifail_cache" 2>/dev/null) || true
  [ -n "$_cifail_cached" ] && echo "$_cifail_cached"
fi

if command -v gh >/dev/null 2>&1; then
  _cifail_url=$(/usr/bin/git config --get remote.origin.url 2>/dev/null || true)
  _cifail_repo=""
  if [ -n "$_cifail_url" ]; then
    _cifail_repo=$(echo "$_cifail_url" | /usr/bin/sed -E 's#^https?://[^/]+/##; s#^git@[^:]+:##; s#\.git$##')
    case "$_cifail_repo" in */*) : ;; *) _cifail_repo="" ;; esac
  fi
  if [ -n "$_cifail_repo" ]; then
    _cifail_debug_log="${HOME}/.claude/logs/session_init_phase14b.log"
    mkdir -p "$(dirname "$_cifail_cache")"
    nohup bash -c "
      _count=\$(timeout 5 gh issue list \
        --repo '$_cifail_repo' --label 'ci-failure' --state open \
        --json number --jq 'length' 2>>'$_cifail_debug_log') || _count=''
      if [ -n \"\$_count\" ] && [ \"\$_count\" -gt 0 ] 2>/dev/null; then
        echo \"ci-failures: \${_count} open  (gh issue list --repo $_cifail_repo --label ci-failure --state open)\" > '$_cifail_cache'
      else
        printf '' > '$_cifail_cache'
      fi
    " > /dev/null 2>&1 &
  fi
fi

# ── Phase 15a: ETL freshness alarm — BACKGROUND (DuckDB query ≤5s) ──────────────
# Cache pattern: show cached line; refresh in background for next session.
# Skippable: CLAUDE_ETL_FRESHNESS_CHECK=0
_etl_cache="${HOME}/.claude/logs/session_init_etl_cache.txt"
if [ "${CLAUDE_ETL_FRESHNESS_CHECK:-1}" != "0" ]; then
  if [ -f "$_etl_cache" ]; then
    _etl_cached=$(cat "$_etl_cache" 2>/dev/null) || true
    [ -n "$_etl_cached" ] && echo "$_etl_cached"
  fi
  _etl_script="${CLAUDE_DIR}/scripts/etl_freshness_check.sh"
  if [ -x "$_etl_script" ]; then
    mkdir -p "$(dirname "$_etl_cache")"
    nohup bash -c "timeout 5 '$_etl_script' --quiet 2>/dev/null > '$_etl_cache' || printf '' > '$_etl_cache'" > /dev/null 2>&1 &
  fi
fi

# ── Phase 15b: Canonical-projects audit — BACKGROUND (DuckDB query ≤5s) ────────
# Skippable: CLAUDE_CANONICAL_PROJECTS_AUDIT=0
_cpaudit_cache="${HOME}/.claude/logs/session_init_cpaudit_cache.txt"
if [ "${CLAUDE_CANONICAL_PROJECTS_AUDIT:-1}" != "0" ]; then
  if [ -f "$_cpaudit_cache" ]; then
    _cpaudit_cached=$(cat "$_cpaudit_cache" 2>/dev/null) || true
    [ -n "$_cpaudit_cached" ] && echo "$_cpaudit_cached"
  fi
  _audit_script="${CLAUDE_DIR}/scripts/canonical_projects_audit.sh"
  if [ -x "$_audit_script" ]; then
    mkdir -p "$(dirname "$_cpaudit_cache")"
    nohup bash -c "timeout 5 '$_audit_script' --quiet 2>/dev/null > '$_cpaudit_cache' || printf '' > '$_cpaudit_cache'" > /dev/null 2>&1 &
  fi
fi

# ── Phase 14: Record session-start SHA (for session-end refine) ───────────────
# Writes HEAD SHA to ~/.claude/.session_start_sha_<project> so that
# session_end_refine.sh can bound a roborev refine to commits from this session.
# One state file per project — concurrent sessions for the same project
# overwrite each other (latest start wins, which is fine).
# No dependency on other phases; safe to run unconditionally.
_sha_project_root=$(git rev-parse --show-toplevel 2>/dev/null) || _sha_project_root=""
if [ -n "$_sha_project_root" ]; then
  _sha_project_name=$(basename "$_sha_project_root")
  _sha_slug=$(echo "$_sha_project_name" | tr '/ ' '__' | sed 's/^_*//')
  _sha_state_file="$CLAUDE_RUNTIME_ROOT/.session_start_sha_${_sha_slug}"
  _sha_head=$(git -C "$_sha_project_root" rev-parse HEAD 2>/dev/null) || _sha_head=""
  if [ -n "$_sha_head" ]; then
    echo "$_sha_head" > "$_sha_state_file"
    # No console output — this is infrastructure, not user-facing info
  fi
fi

exit 0
