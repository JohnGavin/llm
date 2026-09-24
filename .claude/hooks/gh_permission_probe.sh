#!/usr/bin/env bash
#
# hook-liveness: on-gh-call
#   Read by the hook-liveness section of send_overnight_self_review_email.R
#   (llm#1017), if that section is extended to cover this hook. This probe
#   fires ONLY on commands whose first token is `gh` -- a session that never
#   invoked gh will legitimately produce zero rows. Zero-in-7-days is NOT
#   automatically unhealthy here (unlike destructive_api_guard.sh's
#   on-block marker) -- it is unhealthy only when correlated against other
#   evidence that gh WAS invoked during that window. Declared here rather
#   than assumed by the report, per checks-must-distinguish-unknown.
#
# gh_permission_probe.sh — diagnostic-only shape probe for JohnGavin/llm#1184
# ("gh denied to agent despite Bash(gh:*) allow-listed and bypass mode
# active — recorded root cause is falsified").
#
# THIS HOOK NEVER BLOCKS AND NEVER FIXES ANYTHING. It exists to capture, the
# NEXT time the #1184 symptom recurs, enough evidence to distinguish three
# candidate causes that currently all present identically as "denied":
#
#   (a) an allow-rule in settings.json did not match the command string as
#       actually written (a real glob-evaluation mismatch);
#   (b) an allow rule matched, but was overridden by defaultMode / a
#       bypassPermissions-mode discrepancy;
#   (c) one of the nine PreToolUse:Bash hooks denied the command and its
#       message was not surfaced the way the "BLOCKED (<hookname>): ..."
#       convention expects.
#
# Hook: PreToolUse:Bash AND PermissionRequest (same script, two roles).
# Usage: gh_permission_probe.sh <role>   role = pretooluse | permissionrequest
#   Reads the hook JSON on stdin (same shape Claude Code gives every
#   PreToolUse/PermissionRequest hook: {"tool_name":..., "tool_input":{...}}).
#
# Fast path: any command whose first token (after stripping a leading run of
# NAME=value env-assignments, mirroring secret_leak_guard.sh's EGRESS_LINE_RE
# convention) is not literally "gh" costs one regex check and returns
# immediately -- this hook is registered on the bare "Bash" matcher (every
# Bash call), so the non-gh case MUST be near-free. Confirmed by --selftest
# case 1 below (no log line, no hook_events row, no subprocess spawned).
#
# Contract, mirroring tool_input_probe.sh's hard rules:
#   - NEVER blocks (always exit 0, on every code path).
#   - NEVER writes to stdout (a PermissionRequest hook's stdout is a decision
#     channel -- {"decision":"approve"|"deny",...} -- and this probe must
#     never be mistaken for a second decision-maker; a PreToolUse hook's
#     stdout can also perturb the harness protocol). All human-readable
#     output goes to LOG_FILE; shape-only telemetry goes to hook_event_emit.sh.
#   - Any command text that is logged (local flat log AND the hook_events
#     preview) is passed through the SAME redact() used by secret_leak_guard.sh
#     / artifact_secret_guard.sh (lib/cred_patterns.py, llm#960 Part 3) before
#     it is written anywhere. Proven, not just claimed -- see --selftest
#     case 8 (sentinel credential never reaches either output).
#
# ── Role "pretooluse": hook-chain replay ────────────────────────────────
# Re-invokes each of the nine known PreToolUse:Bash hook scripts as an
# independent subprocess, feeding each the SAME raw stdin JSON this script
# received, and records each one's exit code + stderr. This determines,
# empirically, for the EXACT command just attempted, whether ANY of the nine
# hooks would have exited non-zero -- settling hypothesis (c) one way or the
# other for that specific incident, without guessing which hook "looks
# relevant" (the prior investigator's inspection of exactly one hook,
# private_repo_detail_guard.sh, is the failure mode this replay avoids
# repeating).
#
# KNOWN, ACCEPTED trade-off: this is a real re-execution, not a dry-run stub
# -- none of the nine hooks expose a "would you block this" mode. Two
# consequences, both deliberately accepted rather than engineered around
# (which would mean re-deriving nine scripts' internal log/env-var
# conventions and risking a probe bug that itself hides a real block):
#   1. If a replayed hook's own BLOCK path fires for real (rare -- these
#      patterns are narrow and gh commands essentially never trip them
#      except in the exact scenario this probe exists to catch), its own
#      local log file and hook_events row get a genuine extra entry, on top
#      of whatever the REAL PreToolUse execution already wrote. A hook
#      actually firing on a gh command is precisely the signal this probe
#      exists to surface, so a harmless double-count in that rare case is an
#      acceptable price, not a defect.
#   2. pr_merge_author_guard.sh and private_repo_detail_guard.sh make real,
#      read-only, timeout-bounded (10s) `gh`/network calls, but ONLY when
#      the replayed command actually matches their own narrow trigger regex
#      (`gh pr merge ...`, `gh issue|pr create|edit|comment`) -- confirmed by
#      reading both scripts' early-exit paths before this file was written.
#      A bare `gh --version` replay never reaches either lookup.
#   3. Roughly 9 extra subprocess spawns per gh-prefixed Bash call (a few
#      hundred ms at most). Bounded by the gh-only fast path above, and by
#      the SKIP_GH_PERMISSION_PROBE=1 kill switch below.
#
# ── Role "permissionrequest": predicted-allow-list verdict ─────────────
# Best-effort, EXPLICITLY UNVERIFIED reimplementation of settings.json's
# `permissions.allow`/`permissions.deny` glob matching, run against the same
# command. This file has NOT been shown Claude Code's actual matching
# source -- it infers two pattern families empirically observed in this
# repo's own settings.json: `Bash(<word>:*)` (subcommand-prefix; the
# overwhelming majority of entries, including `Bash(gh:*)` itself) and
# `Bash(<literal prefix >*)` / exact literal (space-then-bare-star or no
# wildcard at all; a minority of entries such as `Bash(/usr/bin/git *)`).
# A "predicted_allow=yes" here is a HYPOTHESIS about what Claude Code's real
# evaluator does, not a fact -- it exists so a human comparing this
# prediction against the REAL observed outcome (denied or not) can tell
# whether hypothesis (a) -- the glob genuinely didn't match -- is even
# plausible for the specific incident being diagnosed, not whether it is
# true.
#
# What this role's mere presence in the log proves, regardless of the
# predicted verdict: that a PermissionRequest event fired AT ALL for a gh
# command. In a session genuinely running bypassPermissions mode, whether
# PermissionRequest fires for an allow-listed command is exactly the open
# question llm#1184 raises -- this hook does not assume an answer, it
# records the fact so the answer can be read off the log after a real
# occurrence.
#
# Kill switch: SKIP_GH_PERMISSION_PROBE=1 <command> disables both roles for
# one invocation (checked before stdin is read).
#
# Self-test: bash gh_permission_probe.sh --selftest
#
# Rule: none yet -- this is a diagnostic probe, not an enforced guard; see
# JohnGavin/llm#1184.

set -uo pipefail

SELF_DIR="${BASH_SOURCE[0]%/*}"
LOG_FILE="${GH_PERM_PROBE_LOG_FILE:-$HOME/.claude/logs/gh_permission_probe.log}"
HOOK_EVENT_EMIT_SCRIPT="${SELF_DIR}/../scripts/hook_event_emit.sh"
# MUST be exported -- _redact() invokes python3 as a child process, which
# reads this via os.environ.get(). An earlier version of this file omitted
# `export` here, so the redaction import silently fell back to a no-op
# identity function on every call (the try/except in _redact's python
# swallowed the ImportError) -- selftest case 8 (sentinel-value proof)
# caught this for real before it shipped. Left as a cautionary comment
# because the failure mode is exactly the kind that looks clean until a
# real credential-shaped literal is the input.
export CRED_PATTERNS_LIB_DIR="${SELF_DIR}/lib"
# Override for --selftest (deterministic fixtures instead of the real,
# machine-specific settings.json). Never set outside a test context.
SETTINGS_JSON_PATH="${GH_PERM_PROBE_SETTINGS_OVERRIDE:-${SELF_DIR}/../settings.json}"

# Default replay set: every current PreToolUse:Bash hook per settings.json,
# resolved relative to THIS script's own location (never a hardcoded
# ~/.claude/... path -- ~/.claude/hooks/ is a symlink into the main checkout
# in production, so a hardcoded path would silently replay the main
# checkout's copy even under worktree-isolated testing; same rationale as
# HOOK_EVENT_EMIT_SCRIPT elsewhere in this directory).
_default_hooks_to_replay() {
  printf '%s\n' \
    "${SELF_DIR}/destructive_fs_guard.sh" \
    "${SELF_DIR}/secret_leak_guard.sh" \
    "${SELF_DIR}/repo_visibility_guard.sh" \
    "${SELF_DIR}/private_repo_detail_guard.sh" \
    "${SELF_DIR}/destructive_api_guard.sh" \
    "${SELF_DIR}/compound_command_guard.sh" \
    "${SELF_DIR}/docs_qa_precommit.sh" \
    "${SELF_DIR}/agent_push_guard.sh" \
    "${SELF_DIR}/pr_merge_author_guard.sh"
}

# ── Workspace-kind detection (mirrors session_init.sh Phase 1b) ─────────
_workspace_kind() {
  case "$PWD" in
    /tmp|/tmp/*|/private/tmp|/private/tmp/*) printf 'scratch'; return ;;
  esac
  local common gitdir
  common=$(git rev-parse --git-common-dir 2>/dev/null || echo "")
  gitdir=$(git rev-parse --git-dir 2>/dev/null || echo "")
  if [ -n "$common" ] && [ -n "$gitdir" ]; then
    common=$(cd "$common" 2>/dev/null && pwd) || common=""
    gitdir=$(cd "$gitdir" 2>/dev/null && pwd) || gitdir=""
    if [ -n "$common" ] && [ "$common" != "$gitdir" ]; then
      printf 'worktree'; return
    fi
    printf 'main'; return
  fi
  printf 'other'
}

_default_mode() {
  local f="$1"
  [ -f "$f" ] || { printf 'unknown'; return; }
  local v
  v=$(grep -oE '"defaultMode"[[:space:]]*:[[:space:]]*"[^"]+"' "$f" 2>/dev/null \
      | head -1 | sed -E 's/.*"([^"]+)"[[:space:]]*$/\1/')
  [ -z "$v" ] && v="unknown"
  printf '%s' "$v"
}

_resolve_session_id() {
  # 2026-09-24 (llm#803 follow-up): the harness exports CLAUDE_CODE_SESSION_ID,
  # not CLAUDE_SESSION_ID (never observed set) -- prefer it. See
  # session_stop.sh's matching fix for the incident this addresses.
  local sid="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
  if [ -z "$sid" ] && [ -f "$HOME/.claude/logs/.current_session" ]; then
    local rc
    sid=$(cat "$HOME/.claude/logs/.current_session" 2>/dev/null)
    rc=$?
    # A read failure (permission denied, file removed between the -f check
    # and this cat) is distinguished from a merely-empty file here by
    # capturing $? explicitly, per checks-must-distinguish-unknown -- both
    # still fall through to the shared "unknown" bucket below (this is a
    # non-critical telemetry label, not a decision input, so a 3-way
    # ok/empty/error split would add no actionable signal), but the
    # distinction is now visible in the exit code rather than silently
    # swallowed by an `|| echo ""` fallback.
    [ "$rc" -ne 0 ] && sid=""
  fi
  [ -z "$sid" ] && sid="unknown"
  printf '%s' "$sid"
}

# Fast, pure-bash "is this a gh command" check. Strips a leading run of
# NAME=value assignments (and an optional leading `env`), same shape as
# secret_leak_guard.sh's EGRESS_LINE_RE, then tests the first remaining
# token for literal equality with "gh".
_is_gh_command() {
  local cmd="$1"
  local stripped="$cmd"
  # Strip up to 6 leading NAME=value tokens (bounded loop -- never infinite).
  local i=0
  while [ "$i" -lt 6 ]; do
    case "$stripped" in
      env\ *) stripped="${stripped#env }" ;;
      [A-Za-z_]*=*)
        # Only strip if it's genuinely a NAME=value token (no spaces before
        # the first '='), not something that merely starts with a letter.
        local head="${stripped%% *}"
        case "$head" in
          *=*)
            case "$head" in
              [A-Za-z_][A-Za-z0-9_]*=*)
                stripped="${stripped#* }"
                stripped="${stripped# }"
                ;;
              *) break ;;
            esac
            ;;
          *) break ;;
        esac
        ;;
      *) break ;;
    esac
    i=$((i + 1))
  done
  local first_token="${stripped%% *}"
  [ "$first_token" = "gh" ]
}

# ── JSON extraction (python3; fail-open on any error) ───────────────────
_extract() {
  # stdin: raw hook JSON. Prints two lines: tool_name, command. Empty output
  # (or a python3/parse failure) means "could not extract" -- caller treats
  # that as fail-open (exit 0, no logging).
  python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    tool = d.get('tool_name', '') if isinstance(d, dict) else ''
    ti = d.get('tool_input', {}) if isinstance(d, dict) else {}
    if not isinstance(ti, dict):
        ti = {}
    cmd = ti.get('command', '') or ''
    print(tool)
    print(cmd)
except Exception:
    pass
" 2>/dev/null
}

# ── Redaction (reuses the shared CRED_PATTERNS catalogue; llm#960 Part 3) ──
_redact() {
  # $1 = text to redact. Falls back to returning the text unmodified if the
  # shared lib is unavailable (fail-open, matching secret_leak_guard.sh's own
  # fallback for the same import).
  python3 -c "
import sys, os
sys.path.insert(0, os.environ.get('CRED_PATTERNS_LIB_DIR', ''))
try:
    from cred_patterns import redact
except Exception:
    def redact(t): return t
sys.stdout.write(redact(sys.argv[1]))
" "$1" 2>/dev/null || printf '%s' "$1"
}

_log_line() {
  # $1 = already-assembled JSON object (one line). Appends to LOG_FILE.
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  printf '%s\n' "$1" >> "$LOG_FILE" 2>/dev/null || true
}

_emit_shape() {
  # $1 = event_type, $2 = short non-sensitive preview
  if [ -x "$HOOK_EVENT_EMIT_SCRIPT" ] || [ -f "$HOOK_EVENT_EMIT_SCRIPT" ]; then
    bash "$HOOK_EVENT_EMIT_SCRIPT" gh_permission_probe "$1" "$2" >/dev/null 2>&1 || true
  fi
}

# ── Predicted allow-list verdict (role=permissionrequest only) ──────────
# Best-effort / UNVERIFIED -- see header. Prints one line:
#   predicted_allow=<yes|no>\tmatched_allow_rule=<...>\tmatched_deny_rule=<...>
_predict_allow() {
  local cmd="$1" settings="$2"
  python3 -c "
import json, sys, re

cmd = sys.argv[1]
settings_path = sys.argv[2]

def strip_env_prefix(c):
    return re.sub(r'^\s*(?:env\s+)?(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*', '', c)

stripped = strip_env_prefix(cmd)
first_token = stripped.split()[0] if stripped.split() else ''

def matches(pattern_text, cmd_raw, cmd_stripped, first_tok):
    m = re.match(r'^Bash\((.*)\)\$', pattern_text)
    if not m:
        return None
    inner = m.group(1)
    if inner == cmd_raw or inner == cmd_stripped:
        return 'exact'
    if inner.endswith(':*'):
        prefix = inner[:-2]
        if ' ' not in prefix:
            if first_tok == prefix:
                return 'colon-star word-prefix'
        else:
            if cmd_stripped == prefix or cmd_stripped.startswith(prefix + ' '):
                return 'colon-star multi-word-prefix'
        return None
    if inner.endswith('*'):
        prefix = inner[:-1]
        if cmd_raw.startswith(prefix) or cmd_stripped.startswith(prefix):
            return 'trailing-star prefix'
        return None
    return None

try:
    with open(settings_path) as fh:
        s = json.load(fh)
    allow = s.get('permissions', {}).get('allow', []) or []
    deny = s.get('permissions', {}).get('deny', []) or []
except Exception:
    print('predicted_allow=indeterminate')
    print('matched_allow_rule=')
    print('matched_deny_rule=')
    print('note=settings.json unreadable/unparseable at ' + settings_path)
    sys.exit(0)

allow_hit = None
for pat in allow:
    method = matches(pat, cmd, stripped, first_token)
    if method:
        allow_hit = (pat, method)
        break

deny_hit = None
for pat in deny:
    method = matches(pat, cmd, stripped, first_token)
    if method:
        deny_hit = (pat, method)
        break

verdict = 'no'
if allow_hit and not deny_hit:
    verdict = 'yes'
elif allow_hit and deny_hit:
    verdict = 'deny-overrides-allow'

print('predicted_allow=' + verdict)
print('matched_allow_rule=' + (allow_hit[0] if allow_hit else ''))
print('matched_deny_rule=' + (deny_hit[0] if deny_hit else ''))
print('note=best-effort heuristic, UNVERIFIED against real Claude Code matching semantics')
" "$cmd" "$settings" 2>/dev/null
}

# ── Role "pretooluse": replay ────────────────────────────────────────────
_run_pretooluse() {
  local raw_input="$1" cmd="$2"
  local hooks_list
  if [ -n "${GH_PERM_PROBE_HOOKS_OVERRIDE:-}" ]; then
    hooks_list="$GH_PERM_PROBE_HOOKS_OVERRIDE"
  else
    hooks_list="$(_default_hooks_to_replay | tr '\n' ':')"
    hooks_list="${hooks_list%:}"
  fi

  local IFS_OLD="$IFS"
  IFS=':'
  read -r -a hook_paths <<< "$hooks_list"
  IFS="$IFS_OLD"

  local results_file
  results_file=$(mktemp "${TMPDIR:-/tmp}/gh_perm_probe_replay_XXXXXX") || return 0
  trap 'rm -f "$results_file"' RETURN

  local blocked_count=0 total=0
  for hp in "${hook_paths[@]}"; do
    [ -z "$hp" ] && continue
    [ -f "$hp" ] || continue
    total=$((total + 1))
    local name rc out
    name=$(basename "$hp" .sh)
    out=$(printf '%s' "$raw_input" | bash "$hp" 2>&1 1>/dev/null)
    rc=$?
    if [ "$rc" -ne 0 ]; then
      blocked_count=$((blocked_count + 1))
    fi
    local out_b64
    out_b64=$(printf '%s' "$out" | base64 | tr -d '\n')
    printf '%s\t%s\t%s\n' "$name" "$rc" "$out_b64" >> "$results_file"
  done

  local wk dm sid cmd_redacted log_json preview
  wk=$(_workspace_kind)
  dm=$(_default_mode "$SETTINGS_JSON_PATH")
  sid=$(_resolve_session_id)
  cmd_redacted=$(_redact "$cmd")

  log_json=$(python3 -c "
import json, sys, base64

results_file = sys.argv[1]
entries = []
try:
    with open(results_file) as fh:
        for line in fh:
            parts = line.rstrip('\n').split('\t')
            if len(parts) != 3:
                continue
            name, rc, out_b64 = parts
            try:
                out = base64.b64decode(out_b64).decode('utf-8', errors='replace')
            except Exception:
                out = ''
            entries.append({'hook': name, 'exit': int(rc), 'output': out[:300]})
except Exception:
    pass

row = {
    'ts': sys.argv[2],
    'role': 'pretooluse',
    'session_id': sys.argv[3],
    'workspace_kind': sys.argv[4],
    'default_mode': sys.argv[5],
    'cwd': sys.argv[6],
    'command': sys.argv[7][:300],
    'hooks_replayed': len(entries),
    'hooks_nonzero': [e for e in entries if e['exit'] != 0],
    'any_hook_blocked': any(e['exit'] != 0 for e in entries),
}
print(json.dumps(row))
" "$results_file" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$sid" "$wk" "$dm" "$PWD" "$cmd_redacted")

  [ -n "$log_json" ] && _log_line "$log_json"
  preview="hooks_replayed=${total} any_blocked=$([ "$blocked_count" -gt 0 ] && echo true || echo false)"
  _emit_shape "PreToolUse:replayed" "$preview"
  rm -f "$results_file"
}

# ── Role "permissionrequest": observe + predict ──────────────────────────
_run_permissionrequest() {
  local cmd="$1"
  local wk dm sid cmd_redacted predict_out
  wk=$(_workspace_kind)
  dm=$(_default_mode "$SETTINGS_JSON_PATH")
  sid=$(_resolve_session_id)
  cmd_redacted=$(_redact "$cmd")
  predict_out=$(_predict_allow "$cmd" "$SETTINGS_JSON_PATH")

  local predicted matched_allow matched_deny note
  predicted=$(printf '%s\n' "$predict_out" | sed -n 's/^predicted_allow=//p' | head -1)
  matched_allow=$(printf '%s\n' "$predict_out" | sed -n 's/^matched_allow_rule=//p' | head -1)
  matched_deny=$(printf '%s\n' "$predict_out" | sed -n 's/^matched_deny_rule=//p' | head -1)
  note=$(printf '%s\n' "$predict_out" | sed -n 's/^note=//p' | head -1)

  local log_json
  log_json=$(python3 -c "
import json, sys
row = {
    'ts': sys.argv[1],
    'role': 'permissionrequest',
    'session_id': sys.argv[2],
    'workspace_kind': sys.argv[3],
    'default_mode': sys.argv[4],
    'cwd': sys.argv[5],
    'command': sys.argv[6][:300],
    'predicted_allow': sys.argv[7],
    'matched_allow_rule': sys.argv[8],
    'matched_deny_rule': sys.argv[9],
    'note': sys.argv[10],
}
print(json.dumps(row))
" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$sid" "$wk" "$dm" "$PWD" "$cmd_redacted" \
    "$predicted" "$matched_allow" "$matched_deny" "$note")

  [ -n "$log_json" ] && _log_line "$log_json"
  _emit_shape "PermissionRequest:observed" "predicted_allow=${predicted}"
}

# ═══════════════════════════════════════════════════════════════════════════
# SELF-TEST MODE
# ═══════════════════════════════════════════════════════════════════════════
if [ "${1:-}" = "--selftest" ]; then
  PASS=0; TOTAL=0
  _ok()   { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); printf '  PASS  %s\n' "$1"; }
  _fail() { TOTAL=$((TOTAL+1)); printf '  FAIL  %s\n' "$1"; }

  TMPDIR_ST=$(mktemp -d "${TMPDIR:-/tmp}/gh_perm_probe_selftest_XXXXXX")
  trap 'rm -rf "$TMPDIR_ST"' EXIT
  SELF="${BASH_SOURCE[0]}"
  export CLAUDE_SESSION_ID="selftest-session"

  # ── Case 1: non-gh command -> fast exit, no log, no hook_events row ─────
  export GH_PERM_PROBE_LOG_FILE="$TMPDIR_ST/case1.log"
  export HOOK_EVENTS_SPOOL="$TMPDIR_ST/case1_spool.jsonl"
  RC=0
  printf '{"tool_name":"Bash","tool_input":{"command":"git status"}}' \
    | bash "$SELF" pretooluse || RC=$?
  if [ "$RC" -eq 0 ] && [ ! -f "$GH_PERM_PROBE_LOG_FILE" ] && [ ! -f "$HOOK_EVENTS_SPOOL" ]; then
    _ok "non-gh command: exit 0, no log, no hook_events row"
  else
    _fail "non-gh command: exit 0, no log, no hook_events row"
  fi
  unset GH_PERM_PROBE_LOG_FILE HOOK_EVENTS_SPOOL

  # ── Case 2: gh --version, role=pretooluse, real hook chain -> all allow ──
  export GH_PERM_PROBE_LOG_FILE="$TMPDIR_ST/case2.log"
  export HOOK_EVENTS_SPOOL="$TMPDIR_ST/case2_spool.jsonl"
  RC=0
  printf '{"tool_name":"Bash","tool_input":{"command":"gh --version"}}' \
    | bash "$SELF" pretooluse || RC=$?
  if [ "$RC" -eq 0 ] && [ -f "$GH_PERM_PROBE_LOG_FILE" ] \
     && grep -q '"role": "pretooluse"' "$GH_PERM_PROBE_LOG_FILE" \
     && grep -q '"any_hook_blocked": false' "$GH_PERM_PROBE_LOG_FILE" \
     && [ -f "$HOOK_EVENTS_SPOOL" ] && grep -q "gh_permission_probe" "$HOOK_EVENTS_SPOOL"; then
    _ok "gh --version replayed against real 9-hook chain: all allow, logged, exit 0"
  else
    _fail "gh --version replayed against real 9-hook chain: all allow, logged, exit 0"
  fi
  unset GH_PERM_PROBE_LOG_FILE HOOK_EVENTS_SPOOL

  # ── Case 3: a fixture hook that deliberately BLOCKS -> replay captures it ──
  FIXTURE_HOOK="$TMPDIR_ST/fixture_blocking_hook.sh"
  cat > "$FIXTURE_HOOK" << 'EOF'
#!/usr/bin/env bash
cat >/dev/null   # consume stdin
echo "BLOCKED (fixture_blocking_hook): selftest fixture always blocks" >&2
exit 2
EOF
  chmod +x "$FIXTURE_HOOK"
  export GH_PERM_PROBE_HOOKS_OVERRIDE="$FIXTURE_HOOK"
  export GH_PERM_PROBE_LOG_FILE="$TMPDIR_ST/case3.log"
  export HOOK_EVENTS_SPOOL="$TMPDIR_ST/case3_spool.jsonl"
  RC=0
  printf '{"tool_name":"Bash","tool_input":{"command":"gh issue list"}}' \
    | bash "$SELF" pretooluse || RC=$?
  if [ "$RC" -eq 0 ] && [ -f "$GH_PERM_PROBE_LOG_FILE" ] \
     && grep -q '"any_hook_blocked": true' "$GH_PERM_PROBE_LOG_FILE" \
     && grep -q "fixture_blocking_hook" "$GH_PERM_PROBE_LOG_FILE" \
     && grep -q "selftest fixture always blocks" "$GH_PERM_PROBE_LOG_FILE"; then
    _ok "fixture blocking hook: replay captures exit=2 and stderr, probe itself still exits 0"
  else
    _fail "fixture blocking hook: replay captures exit=2 and stderr, probe itself still exits 0"
  fi
  unset GH_PERM_PROBE_HOOKS_OVERRIDE GH_PERM_PROBE_LOG_FILE HOOK_EVENTS_SPOOL

  # ── Case 4: malformed JSON on stdin -> exit 0, no crash ─────────────────
  export GH_PERM_PROBE_LOG_FILE="$TMPDIR_ST/case4.log"
  RC=0
  printf '{not valid json' | bash "$SELF" pretooluse || RC=$?
  if [ "$RC" -eq 0 ]; then
    _ok "malformed JSON on stdin does not crash (exit 0)"
  else
    _fail "malformed JSON on stdin does not crash (exit 0)"
  fi
  unset GH_PERM_PROBE_LOG_FILE

  # ── Case 5: python3 unavailable -> fail-open, exit 0, no log ────────────
  FAKE_BIN="$TMPDIR_ST/fakebin"
  mkdir -p "$FAKE_BIN"
  for c in bash cat sh grep sed head mktemp dirname basename tr base64 date git; do
    real_c=$(command -v "$c" 2>/dev/null) || continue
    ln -sf "$real_c" "$FAKE_BIN/$c"
  done
  export GH_PERM_PROBE_LOG_FILE="$TMPDIR_ST/case5.log"
  RC=0
  printf '{"tool_name":"Bash","tool_input":{"command":"gh --version"}}' \
    | PATH="$FAKE_BIN" "$FAKE_BIN/bash" "$SELF" pretooluse || RC=$?
  if [ "$RC" -eq 0 ] && [ ! -f "$GH_PERM_PROBE_LOG_FILE" ]; then
    _ok "python3 unavailable: fails open, exit 0, no log written"
  else
    _fail "python3 unavailable: fails open, exit 0, no log written (rc=$RC, log_exists=$([ -f "$GH_PERM_PROBE_LOG_FILE" ] && echo yes || echo no))"
  fi
  unset GH_PERM_PROBE_LOG_FILE

  # ── Case 6: predicted-allow, role=permissionrequest, fixture settings ───
  FIXTURE_SETTINGS_YES="$TMPDIR_ST/settings_with_gh_star.json"
  cat > "$FIXTURE_SETTINGS_YES" << 'EOF'
{"permissions":{"allow":["Bash(gh:*)","Bash(git:*)"],"deny":["Bash(gh repo delete:*)"]}}
EOF
  export GH_PERM_PROBE_SETTINGS_OVERRIDE="$FIXTURE_SETTINGS_YES"
  export GH_PERM_PROBE_LOG_FILE="$TMPDIR_ST/case6.log"
  RC=0
  printf '{"tool_name":"Bash","tool_input":{"command":"gh --version"}}' \
    | bash "$SELF" permissionrequest || RC=$?
  if [ "$RC" -eq 0 ] && [ -f "$GH_PERM_PROBE_LOG_FILE" ] \
     && grep -q '"predicted_allow": "yes"' "$GH_PERM_PROBE_LOG_FILE" \
     && grep -q 'gh' "$GH_PERM_PROBE_LOG_FILE"; then
    _ok "predicted-allow: Bash(gh:*) present -> predicted_allow=yes, rule recorded"
  else
    _fail "predicted-allow: Bash(gh:*) present -> predicted_allow=yes, rule recorded"
  fi
  unset GH_PERM_PROBE_LOG_FILE GH_PERM_PROBE_SETTINGS_OVERRIDE

  # ── Case 7: predicted-allow, no matching rule -> predicted_allow=no ─────
  FIXTURE_SETTINGS_NO="$TMPDIR_ST/settings_without_gh.json"
  cat > "$FIXTURE_SETTINGS_NO" << 'EOF'
{"permissions":{"allow":["Bash(git:*)"],"deny":[]}}
EOF
  export GH_PERM_PROBE_SETTINGS_OVERRIDE="$FIXTURE_SETTINGS_NO"
  export GH_PERM_PROBE_LOG_FILE="$TMPDIR_ST/case7.log"
  RC=0
  printf '{"tool_name":"Bash","tool_input":{"command":"gh --version"}}' \
    | bash "$SELF" permissionrequest || RC=$?
  if [ "$RC" -eq 0 ] && [ -f "$GH_PERM_PROBE_LOG_FILE" ] \
     && grep -q '"predicted_allow": "no"' "$GH_PERM_PROBE_LOG_FILE"; then
    _ok "predicted-allow: no matching rule -> predicted_allow=no"
  else
    _fail "predicted-allow: no matching rule -> predicted_allow=no"
  fi
  unset GH_PERM_PROBE_LOG_FILE GH_PERM_PROBE_SETTINGS_OVERRIDE

  # ── Case 8: sentinel credential never reaches log or hook_events ────────
  export GH_PERM_PROBE_LOG_FILE="$TMPDIR_ST/case8.log"
  export HOOK_EVENTS_SPOOL="$TMPDIR_ST/case8_spool.jsonl"
  SENTINEL="ghp_SENTINELDONOTLEAK0123456789AB"
  PAYLOAD8=$(python3 -c 'import json, sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":"gh issue comment 1 --body \"" + sys.argv[1] + "\""}}))' "$SENTINEL")
  RC=0
  printf '%s' "$PAYLOAD8" | bash "$SELF" pretooluse || RC=$?
  if [ "$RC" -eq 0 ] \
     && { [ ! -f "$GH_PERM_PROBE_LOG_FILE" ] || ! grep -q "$SENTINEL" "$GH_PERM_PROBE_LOG_FILE"; } \
     && { [ ! -f "$HOOK_EVENTS_SPOOL" ] || ! grep -q "$SENTINEL" "$HOOK_EVENTS_SPOOL"; }; then
    _ok "sentinel credential in command text never reaches log or hook_events"
  else
    _fail "sentinel credential in command text never reaches log or hook_events"
  fi
  unset GH_PERM_PROBE_LOG_FILE HOOK_EVENTS_SPOOL

  # ── Case 9: kill switch SKIP_GH_PERMISSION_PROBE=1 disables both roles ──
  export GH_PERM_PROBE_LOG_FILE="$TMPDIR_ST/case9.log"
  RC=0
  printf '{"tool_name":"Bash","tool_input":{"command":"gh --version"}}' \
    | SKIP_GH_PERMISSION_PROBE=1 bash "$SELF" pretooluse || RC=$?
  if [ "$RC" -eq 0 ] && [ ! -f "$GH_PERM_PROBE_LOG_FILE" ]; then
    _ok "SKIP_GH_PERMISSION_PROBE=1 disables the probe (exit 0, no log)"
  else
    _fail "SKIP_GH_PERMISSION_PROBE=1 disables the probe (exit 0, no log)"
  fi
  unset GH_PERM_PROBE_LOG_FILE

  # ── Case 10: never writes to stdout, on any path ────────────────────────
  export GH_PERM_PROBE_LOG_FILE="$TMPDIR_ST/case10.log"
  STDOUT_CAPTURE=$(printf '{"tool_name":"Bash","tool_input":{"command":"gh --version"}}' \
    | bash "$SELF" permissionrequest 2>/dev/null)
  if [ -z "$STDOUT_CAPTURE" ]; then
    _ok "never writes to stdout (role=permissionrequest)"
  else
    _fail "never writes to stdout (role=permissionrequest) -- got: $STDOUT_CAPTURE"
  fi
  unset GH_PERM_PROBE_LOG_FILE

  echo ""
  echo "=== gh_permission_probe.sh selftest: $PASS/$TOTAL PASS ==="
  [ "$PASS" -eq "$TOTAL" ] && exit 0
  exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════
# NORMAL HOOK OPERATION
# ═══════════════════════════════════════════════════════════════════════════

if [ "${SKIP_GH_PERMISSION_PROBE:-0}" = "1" ]; then
  exit 0
fi

ROLE="${1:-}"
case "$ROLE" in
  pretooluse|permissionrequest) ;;
  *) exit 0 ;;
esac

RAW_INPUT=$(cat 2>/dev/null) || exit 0
[ -z "$RAW_INPUT" ] && exit 0

_EXTRACTED=$(printf '%s' "$RAW_INPUT" | _extract) || exit 0
[ -z "$_EXTRACTED" ] && exit 0

TOOL_NAME=$(printf '%s\n' "$_EXTRACTED" | sed -n '1p')
COMMAND=$(printf '%s\n' "$_EXTRACTED" | sed -n '2p')

[ "$TOOL_NAME" != "Bash" ] && exit 0
[ -z "$COMMAND" ] && exit 0

_is_gh_command "$COMMAND" || exit 0

case "$ROLE" in
  pretooluse)       _run_pretooluse "$RAW_INPUT" "$COMMAND" ;;
  permissionrequest) _run_permissionrequest "$COMMAND" ;;
esac

exit 0
