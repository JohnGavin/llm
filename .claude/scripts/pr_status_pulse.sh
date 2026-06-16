#!/usr/bin/env bash
# pr_status_pulse.sh — log open PR + CI status across tracked repos
# Part of #137 Phase 4 cron density.
#
# What it does: for each repo with an active PR by the user, log:
#   - branch, PR number, mergeable state
#   - latest GH Actions run conclusion
# Output: ~/.claude/logs/pr_status.log (rolling, one block per fire)
# Exit codes: always 0 (silent failure on network glitches; this is a
#             low-priority pulse, not a gate).

set -uo pipefail  # NOT -e — single repo failure must not kill the pass

GH="${GH:-/opt/homebrew/bin/gh}"
LOG="$HOME/.claude/logs/pr_status.log"
mkdir -p "$(dirname "$LOG")"

# Quietly succeed if gh isn't installed
if [ ! -x "$GH" ]; then
  GH="$(command -v gh 2>/dev/null || true)"
  [ -z "$GH" ] && exit 0
fi

repos=(
  "JohnGavin/llm"
  "JohnGavin/llmtelemetry"
  "JohnGavin/randomwalk"
  "JohnGavin/irishbuoys"
)

{
  echo "═══════════════════════════════════════════════════════════════"
  echo "PR status pulse — $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "═══════════════════════════════════════════════════════════════"

  for repo in "${repos[@]}"; do
    prs=$("$GH" pr list --repo "$repo" --json number,title,headRefName,isDraft,mergeable,statusCheckRollup --limit 20 2>/dev/null || true)
    [ -z "$prs" ] || [ "$prs" = "[]" ] && continue

    echo
    echo "── $repo ──"
    echo "$prs" | python3 -c "
import json, sys
prs = json.load(sys.stdin)
for p in prs:
    n = p.get('number'); t = p.get('title','')[:60]; branch = p.get('headRefName','')
    draft = ' [DRAFT]' if p.get('isDraft') else ''
    merg = p.get('mergeable','UNKNOWN')
    checks = p.get('statusCheckRollup') or []
    cs = {}
    for c in checks:
        s = c.get('conclusion') or c.get('status') or '?'
        cs[s] = cs.get(s, 0) + 1
    cs_str = ', '.join(f'{k}={v}' for k,v in sorted(cs.items())) or '(no checks)'
    print(f'  #{n}{draft} {branch}: {t}')
    print(f'    mergeable={merg} | {cs_str}')
" 2>/dev/null
  done

  echo
} >> "$LOG" 2>&1

# Stamp for cron_catchup.sh catch-up detection
mkdir -p "${HOME}/.claude/logs/stamps"
date -u +%Y-%m-%dT%H:%M:%SZ > "${HOME}/.claude/logs/stamps/pr-status-pulse.stamp"

exit 0
