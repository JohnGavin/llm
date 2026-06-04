#!/usr/bin/env bash
# audit_mermaid_dashboards.sh — sweep .qmd source files for mermaid-dashboard
# pattern violations. Complements L1 (PreToolUse guard, catches new edits) and
# L2 (post-render verifier, catches rendered HTML failures). L4 catches
# pre-existing .qmd files that pre-date the rule.
#
# Rule:     mermaid-dashboard-pattern
# Hook:     ~/.claude/hooks/mermaid_dashboard_guard.sh (L1)
# Verify:   ~/.claude/scripts/verify_mermaid_dashboard.sh (L2)
# Template: ~/docs_gh/llm/.claude/templates/mermaid-dashboard/
#
# Usage:
#   audit_mermaid_dashboards.sh [path]   (default: current directory)
#   audit_mermaid_dashboards.sh --selftest
#
# Violations detected:
#   V1 — ```{mermaid} chunk inside a ::: {.panel-tabset} block
#        (same fail-mode L1 blocks at edit time)
#
# Exit codes:
#   0  no violations OR no .qmd files in path
#   1  one or more violations (reported to stderr)
#   2  bad invocation

set -u
set -o pipefail

LOG="${HOME}/.claude/logs/audit_mermaid_dashboards.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true

ts()  { date -u +'%Y-%m-%dT%H:%M:%SZ'; }
log() { printf '%s %s\n' "$(ts)" "$*" >> "$LOG"; }

# ── Scan a single .qmd file for V1. Returns line number of the first
#    offending {mermaid} chunk on stdout (empty if clean). Uses a state
#    machine: in_tabset flips on `::: {.panel-tabset}`, off on the matching
#    closing `:::` (we count `:::` opens/closes to handle nested blocks).
scan_qmd() {
  local f="$1"
  awk '
    BEGIN { depth = 0; mermaid_line = 0 }
    # Opening of any fenced div: ::: {.xxx}
    /^:::[[:space:]]*\{[^}]*\}/ {
      if ($0 ~ /\.panel-tabset/) { depth++ }
      else if (depth > 0)        { depth++ }   # nested non-tabset block
      next
    }
    # Bare `:::` closing
    /^:::[[:space:]]*$/ {
      if (depth > 0) depth--
      next
    }
    # mermaid chunk start: ```{mermaid …}
    /^```\{mermaid/ {
      if (depth > 0 && mermaid_line == 0) {
        mermaid_line = NR
      }
    }
    END {
      if (mermaid_line > 0) print mermaid_line
    }
  ' "$f" 2>/dev/null
}

# ── Selftest ─────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--selftest" ]; then
  tmp=$(mktemp -d -t audit_mermaid_selftest.XXXX)
  trap 'rm -rf "$tmp"' EXIT
  pass=0; fail=0; total=0
  _ok()   { total=$((total+1)); pass=$((pass+1)); printf '  PASS  %s\n' "$*"; }
  _fail() { total=$((total+1)); fail=$((fail+1)); printf '  FAIL  %s\n' "$*"; }

  # V1: mermaid chunk inside tabset → flag
  cat > "$tmp/v1.qmd" <<'QMD'
# Page

::: {.panel-tabset}

## Tab A

```{mermaid}
graph TD
  A-->B
```

:::
QMD
  ln=$(scan_qmd "$tmp/v1.qmd")
  [ -n "$ln" ] && _ok "V1 flagged ({mermaid} inside tabset, line $ln)" \
              || _fail "V1 not flagged"

  # V1 negative: flat-page mermaid → ALLOW
  cat > "$tmp/flat.qmd" <<'QMD'
# Page

```{mermaid}
graph TD
  A-->B
```
QMD
  ln=$(scan_qmd "$tmp/flat.qmd")
  [ -z "$ln" ] && _ok "V1 negative (flat-page mermaid)" \
              || _fail "V1 false-positive on flat page (ln=$ln)"

  # V1 negative: tabset using mount-div pattern → ALLOW
  cat > "$tmp/mount.qmd" <<'QMD'
# Page

::: {.panel-tabset}

## Tab A

<div id="arch-mount"></div>

:::
QMD
  ln=$(scan_qmd "$tmp/mount.qmd")
  [ -z "$ln" ] && _ok "V1 negative (mount-div in tabset)" \
              || _fail "V1 false-positive on mount-div (ln=$ln)"

  # V1 negative: tabset closes BEFORE mermaid → ALLOW
  cat > "$tmp/after.qmd" <<'QMD'
# Page

::: {.panel-tabset}

## Tab A

foo

:::

```{mermaid}
graph TD
  A-->B
```
QMD
  ln=$(scan_qmd "$tmp/after.qmd")
  [ -z "$ln" ] && _ok "V1 negative (mermaid after tabset closed)" \
              || _fail "V1 false-positive on after-tabset (ln=$ln)"

  # End-to-end: directory with one violating + one clean
  mkdir -p "$tmp/proj"
  cp "$tmp/v1.qmd" "$tmp/proj/a.qmd"
  cp "$tmp/flat.qmd" "$tmp/proj/b.qmd"
  bash "$0" "$tmp/proj" >/dev/null 2>&1
  rc=$?; [ "$rc" -eq 1 ] && _ok "end-to-end: violations → exit 1" \
                       || _fail "end-to-end: wrong exit ($rc)"

  # End-to-end: clean directory
  mkdir -p "$tmp/clean"
  cp "$tmp/flat.qmd" "$tmp/clean/a.qmd"
  cp "$tmp/mount.qmd" "$tmp/clean/b.qmd"
  bash "$0" "$tmp/clean" >/dev/null 2>&1
  rc=$?; [ "$rc" -eq 0 ] && _ok "end-to-end: clean dir → exit 0" \
                       || _fail "end-to-end: clean wrong exit ($rc)"

  # End-to-end: empty dir (no qmd) → exit 0
  mkdir -p "$tmp/empty"
  bash "$0" "$tmp/empty" >/dev/null 2>&1
  rc=$?; [ "$rc" -eq 0 ] && _ok "end-to-end: empty dir → exit 0" \
                       || _fail "end-to-end: empty wrong exit ($rc)"

  printf '\naudit_mermaid_dashboards selftest: %d/%d PASS\n' "$pass" "$total"
  [ "$fail" -eq 0 ] && exit 0 || exit 1
fi

# ── Production ───────────────────────────────────────────────────────────────
path="${1:-.}"
if [ ! -d "$path" ] && [ ! -f "$path" ]; then
  printf 'audit_mermaid_dashboards: not found: %s\n' "$path" >&2
  exit 2
fi

# Collect .qmd files
if [ -d "$path" ]; then
  files=$(find "$path" -type f -name '*.qmd' 2>/dev/null \
            ! -path '*/.git/*' \
            ! -path '*/_freeze/*' \
            ! -path '*/_targets/*' \
            ! -path '*/node_modules/*' \
            ! -path '*/.claude/templates/*')
else
  files="$path"
fi

violations=0
for f in $files; do
  [ -f "$f" ] || continue
  ln=$(scan_qmd "$f")
  if [ -n "$ln" ]; then
    printf '  [V1] %s:%s — ```{mermaid} chunk inside ::: {.panel-tabset}\n' "$f" "$ln" >&2
    violations=$((violations + 1))
  fi
done

if [ "$violations" -gt 0 ]; then
  cat >&2 <<EOF

audit_mermaid_dashboards: $violations violation(s) of mermaid-dashboard-pattern

Fix each violation by replacing the {mermaid} chunk with a mount-div and an
inline diagrams module. See:
  Rule:     ~/docs_gh/llm/.claude/rules/mermaid-dashboard-pattern.md
  Template: ~/docs_gh/llm/.claude/templates/mermaid-dashboard/
  Scaffold: ~/.claude/scripts/scaffold-mermaid-dashboard.sh
EOF
  log "VIOLATIONS n=$violations path=$path"
  exit 1
fi

log "OK path=$path"
exit 0
