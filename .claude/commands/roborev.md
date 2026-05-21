# /roborev - Toggle roborev auto code review

Toggle the roborev post-commit hook on or off for a project.

## Arguments

- `$ARGUMENTS` — `on`, `off`, or `status` (default: `status`)

## Steps

1. Determine the target repo (use the current working directory)
2. Check if the post-commit hook exists and contains "roborev"
3. Based on the argument:
   - `on` — run `roborev install-hook` in the repo
   - `off` — run `roborev uninstall-hook` in the repo
   - `status` — report whether the hook is installed

## Commands

```bash
REPO_DIR="${PWD}"
HOOK="${REPO_DIR}/.git/hooks/post-commit"
# Note: $ARGUMENTS is the documented variable for slash commands, but bash scripts receive $1
ARG="${ARGUMENTS:-${1:-status}}"

case "$ARG" in
  on)
    # Subshell isolates cd (documented exception to no-compound-commands rule)
    (cd "$REPO_DIR" && roborev install-hook)
    AGENT=$(grep '^default_agent = ' ~/.roborev/config.toml 2>/dev/null | cut -d"'" -f2 || echo "codex")
    echo "roborev hook INSTALLED for $(basename "$REPO_DIR")"
    echo "Every commit will be auto-reviewed (agent: $AGENT)"
    ;;
  off)
    (cd "$REPO_DIR" && roborev uninstall-hook)
    echo "roborev hook REMOVED for $(basename "$REPO_DIR")"
    echo "Use 'roborev review --since HEAD~1' for manual reviews"
    ;;
  status|*)
    if [ -f "$HOOK" ] && grep -q "roborev" "$HOOK" 2>/dev/null; then
      AGENT=$(grep '^default_agent = ' ~/.roborev/config.toml 2>/dev/null | cut -d"'" -f2 || echo "unknown")
      echo "roborev: ON for $(basename "$REPO_DIR") (agent: $AGENT)"
      echo "Last 5 reviews:"
      roborev list --limit 5 2>/dev/null || echo "  (daemon not running)"

      # Severity-autoclose suppression count (llm#224 Phase 4 — F2 visibility)
      # Only shown if counter file exists and today's count > 0.
      _COUNTER_FILE="${HOME}/.claude/.roborev_autoclose_counters.json"
      _REPO_NAME=$(basename "$REPO_DIR")
      if [ -f "$_COUNTER_FILE" ]; then
        _SUPPRESSED=$(ROBOREV_COUNTER_FILE="$_COUNTER_FILE" ROBOREV_REPO_NAME="$_REPO_NAME" python3 << 'PYEOF'
import json, sys, os
from datetime import datetime, timezone

counter_file = os.environ.get("ROBOREV_COUNTER_FILE", "")
repo_name = os.environ.get("ROBOREV_REPO_NAME", "unknown")

try:
    with open(counter_file, "r") as f:
        data = json.load(f)
except Exception:
    sys.exit(0)

today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
by_date = data.get("by_date", {})
today_entry = by_date.get(today, {})

# Effective threshold (most recent)
threshold = "unknown"
for date_key in sorted(by_date.keys(), reverse=True):
    t_obs = by_date[date_key].get("threshold_observed", {})
    if repo_name in t_obs:
        threshold = t_obs[repo_name]
        break
    elif t_obs:
        threshold = next(iter(t_obs.values()))
        break

# Today's closed count for this repo
by_repo = today_entry.get("by_repo", {})
if repo_name in by_repo:
    closed = int(by_repo[repo_name].get("closed", 0))
else:
    closed = int(today_entry.get("closed_count", 0))

if closed > 0:
    print(f"Suppressed by severity threshold: {closed} (threshold={threshold})")
PYEOF
        )
        [ -n "$_SUPPRESSED" ] && echo "$_SUPPRESSED"
      fi
    else
      echo "roborev: OFF for $(basename "$REPO_DIR")"
      echo "Enable with: /roborev on"
    fi
    ;;
esac
```

## Notes

- The hook uses the agent configured in `~/.roborev/config.toml` (currently codex for auto, use `--agent claude` for manual)
- To skip a single commit: `git commit --no-verify`
- To see all reviews: `roborev tui`
- To run a manual Claude review: `roborev refine --agent claude --since HEAD~1`
