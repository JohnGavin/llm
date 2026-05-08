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
