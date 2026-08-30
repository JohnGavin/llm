#!/usr/bin/env bash
#
# private_repo_detail_guard.sh — Block a PUBLIC-repo publish action
# (gh issue create/edit/comment, gh pr create/edit/comment) whose command
# text or --body-file contents mention the name or path of a repo classified
# private / local_only / confidential_by_policy by repo_visibility.sh.
#
# Hook: PreToolUse:Bash
# Exit 2 = BLOCK. Exit 0 = allow.
#
# JohnGavin/llm#794 item 2. Rule: .claude/rules/private-repo-detail-locality.md
#
# Source: JohnGavin/llm#792 — the first published revision of a cross-project
# audit issue named a private, local-only repo (file paths, account kinds,
# broker) plus two repos llmtelemetry's own excluded_dashboard_projects()
# classifies as confidential. Redacted within minutes, but the sequence was
# wrong: published, THEN checked. This hook fires BEFORE gh runs, at the
# only point where the mistake is still reversible — GitHub retains issue
# edit history and subscribers may already have been emailed the original
# body, so a post-publish redaction is incomplete by design.
#
# Design notes:
#   * Fast substring pre-check before any heavier work (mirrors
#     secret_leak_guard.sh's fast-path discipline) — this hook fires on
#     EVERY Bash call, so anything that is not a gh issue/pr publish verb
#     must cost ~0.
#   * Target-repo resolution: an explicit --repo/-R flag on the command
#     first, else the invoking directory's git remote (git -C "$PWD" ...) —
#     a PreToolUse hook inherits the same cwd as the Bash tool call it is
#     gating.
#   * Scan condition: repo_visibility.sh classify <target> returns anything
#     OTHER than private/local_only/confidential_by_policy — i.e. the scan
#     runs when the target is `public` OR `unknown`. Per repo_visibility.sh's
#     own policy ("a lookup failure must not read as safe to publish"),
#     `unknown` is treated the SAME as `public` here: an unresolved lookup
#     must not silently skip the guard just because it also can't confirm
#     the risk.
#   * The candidate list of non-public repo names/paths comes from
#     `repo_visibility.sh candidates` — fast, cached, NEVER rebuilt inline by
#     this hook (a cold rebuild scans every repo under ~/docs_gh and shells
#     out to `gh repo view` for each; that cannot happen inside a 5-15s hook
#     budget). If the candidates cache has never been seeded, the list is
#     empty and this hook is a no-op until someone runs
#     `repo_visibility.sh candidates --refresh` once.
#   * Only candidate NAMES >= PRIVATE_DETAIL_MIN_NAME_LEN characters (default
#     6) are used as scan terms — a repo literally named e.g. "R" or "1c"
#     would false-positive on ordinary prose constantly. Candidate PATHS are
#     always used regardless of length (an absolute path is inherently
#     distinctive, unlike a short bare word).
#   * Bypassable via a command-string PREFIX
#     (PRIVATE_DETAIL_GUARD_BYPASS=1 <command>) — the same interface
#     convention secret_leak_guard.sh uses for SECRET_GUARD_BYPASS. An
#     ordinary Bash-tool caller cannot rely on a separate `export`, because
#     shell state does not persist between Bash tool calls; the bypass must
#     be expressible as a literal prefix on the command string that will
#     actually run.
#   * Fail-open on any internal error (missing repo_visibility.sh, gh
#     unavailable, malformed JSON) — a broken guard must never wedge a
#     session. This is a fail-open HOOK wrapping a fail-CLOSED classifier:
#     repo_visibility.sh itself never reports "public" on a lookup failure,
#     but if THIS script errors out before even calling the classifier, it
#     allows the command through rather than blocking unrelated work.
#
# Self-test: bash private_repo_detail_guard.sh --selftest

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_VISIBILITY_SCRIPT="${PRIVATE_DETAIL_REPO_VISIBILITY_SCRIPT:-$SCRIPT_DIR/../scripts/repo_visibility.sh}"
MIN_NAME_LEN="${PRIVATE_DETAIL_MIN_NAME_LEN:-6}"
LOG_DIR="${PRIVATE_DETAIL_LOG_DIR:-$HOME/.claude/logs}"
LOG="$LOG_DIR/private_repo_detail_guard.log"
BODY_FILE_READ_CAP=262144   # 256 KiB, same cap secret_leak_guard.sh uses

_log() {
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$LOG" 2>/dev/null || true
}

# ─── fast pre-check ──────────────────────────────────────────────────────────
_is_candidate_command() {
  case "$1" in
    *"gh issue create"*|*"gh issue edit"*|*"gh issue comment"*| \
    *"gh pr create"*|*"gh pr edit"*|*"gh pr comment"*)
      return 0 ;;
    *) return 1 ;;
  esac
}

# ─── bypass, command-string PREFIX form only ────────────────────────────────
_bypass_present() {
  local cmd="$1"
  [[ "$cmd" =~ ^[[:space:]]*(env[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*PRIVATE_DETAIL_GUARD_BYPASS=1([[:space:]]|$) ]]
}

# ─── extract --repo/-R OWNER/REPO from the command, if present ─────────────
_extract_repo_flag() {
  local cmd="$1" raw=""
  if [[ "$cmd" =~ --repo(=|[[:space:]]+)(\"[^\"]+\"|\'[^\']+\'|[^[:space:]]+) ]]; then
    raw="${BASH_REMATCH[2]}"
  elif [[ "$cmd" =~ (^|[[:space:]])-R[[:space:]]+(\"[^\"]+\"|\'[^\']+\'|[^[:space:]]+) ]]; then
    raw="${BASH_REMATCH[2]}"
  else
    return 1
  fi
  raw="${raw%\"}"; raw="${raw#\"}"
  raw="${raw%\'}"; raw="${raw#\'}"
  printf '%s' "$raw"
}

# ─── extract --body-file <path>, if present (not "-" / stdin) ──────────────
_extract_body_file() {
  local cmd="$1" raw=""
  if [[ "$cmd" =~ --body-file(=|[[:space:]]+)(\"[^\"]*\"|\'[^\']*\'|[^[:space:]]+) ]]; then
    raw="${BASH_REMATCH[2]}"
  else
    return 1
  fi
  raw="${raw%\"}"; raw="${raw#\"}"
  raw="${raw%\'}"; raw="${raw#\'}"
  [ -n "$raw" ] && [ "$raw" != "-" ] || return 1
  printf '%s' "$raw"
}

_classify() {
  # Wraps repo_visibility.sh classify, fail-open (prints "unknown" on any
  # internal error running the classifier itself — NOT the same thing as
  # repo_visibility.sh's own affirmative `unknown` return, but treated
  # identically by the caller, which is the correct fail-closed-for-scanning
  # behaviour either way).
  local target="$1" out
  [ -x "$REPO_VISIBILITY_SCRIPT" ] || { printf 'unknown'; return; }
  out="$(bash "$REPO_VISIBILITY_SCRIPT" classify "$target" 2>/dev/null)" || out=""
  printf '%s' "${out:-unknown}"
}

main() {
  local payload cmd
  payload="$(cat 2>/dev/null || true)"
  cmd="$(printf '%s' "$payload" | python3 -c '
import sys,json
try:
    d=json.load(sys.stdin)
except Exception:
    print(""); raise SystemExit
print((d.get("tool_input") or {}).get("command") or d.get("command") or "")' 2>/dev/null || true)"
  [ -n "$cmd" ] || exit 0

  _is_candidate_command "$cmd" || exit 0

  if _bypass_present "$cmd"; then
    _log "BYPASS cmd=${cmd:0:200}"
    exit 0
  fi

  local target
  target="$(_extract_repo_flag "$cmd")" || target="$PWD"

  local target_vis
  target_vis="$(_classify "$target")"
  case "$target_vis" in
    private|local_only|confidential_by_policy)
      # Target is not public — out of scope for this guard.
      exit 0
      ;;
  esac
  # public or unknown -> proceed to scan.

  local candidates
  candidates="$(bash "$REPO_VISIBILITY_SCRIPT" candidates 2>/dev/null || true)"
  [ -n "$candidates" ] || exit 0   # nothing to scan for yet (cache never seeded)

  local scan_text="$cmd"
  local body_file
  if body_file="$(_extract_body_file "$cmd")"; then
    if [ -f "$body_file" ]; then
      local body_content
      body_content="$(head -c "$BODY_FILE_READ_CAP" "$body_file" 2>/dev/null || true)"
      scan_text="$scan_text
$body_content"
    fi
  fi

  local name path vis home_form matched_term=""
  while IFS=$'\t' read -r name path vis; do
    [ -n "$name" ] || continue
    if [ "${#name}" -ge "$MIN_NAME_LEN" ]; then
      if printf '%s' "$scan_text" | grep -qF -- "$name"; then
        matched_term="$name"
        break
      fi
    fi
    if [ -n "$path" ]; then
      if printf '%s' "$scan_text" | grep -qF -- "$path"; then
        matched_term="$path"
        break
      fi
      home_form="${path/#$HOME/~}"
      if [ "$home_form" != "$path" ] && printf '%s' "$scan_text" | grep -qF -- "$home_form"; then
        matched_term="$home_form"
        break
      fi
    fi
  done <<< "$candidates"

  if [ -n "$matched_term" ]; then
    _log "BLOCK target=$target target_vis=$target_vis term=$matched_term cmd=${cmd:0:200}"
    {
      echo "BLOCKED (private_repo_detail_guard): this command publishes to a"
      echo "$target_vis repo, and its content mentions '$matched_term' — the"
      echo "name or path of a repo classified private/local_only/"
      echo "confidential_by_policy by repo_visibility.sh."
      echo
      echo "Detail about a private repo belongs IN that repo (its own issue"
      echo "tracker, or a local issues/NNNN-*.md convention if it has no"
      echo "remote) — never in a public cross-project artifact. A public"
      echo "artifact may carry a stable alias and a count, nothing more."
      echo
      echo "See: .claude/rules/private-repo-detail-locality.md"
      echo "Log: $LOG"
    } >&2
    exit 2
  fi

  exit 0
}

# ═══════════════════════════════════════════════════════════════════════════
# SELF-TEST — SYNTHETIC repo names only, never real ones.
# ═══════════════════════════════════════════════════════════════════════════
if [ "${1:-}" = "--selftest" ]; then
  TMP_DIR="$(mktemp -d /tmp/private_repo_detail_guard_selftest_XXXXXX)"
  export PRIVATE_DETAIL_LOG_DIR="$TMP_DIR/logs"
  export REPO_VISIBILITY_CACHE_FILE="$TMP_DIR/rv_cache.tsv"
  export REPO_VISIBILITY_CANDIDATES_FILE="$TMP_DIR/rv_candidates.tsv"
  export REPO_VISIBILITY_CONFIDENTIAL_LIST="$TMP_DIR/rv_confidential.txt"
  : > "$REPO_VISIBILITY_CONFIDENTIAL_LIST"

  # Seed the candidates cache with a SYNTHETIC private repo — never a real one.
  printf 'test-private-repo-xyz\t%s/fake/test-private-repo-xyz\tprivate\n' "$TMP_DIR" \
    > "$REPO_VISIBILITY_CANDIDATES_FILE"
  date -u +%s > "${REPO_VISIBILITY_CANDIDATES_FILE}.epoch"

  # Seed the single-repo cache with fixed classifications for fake targets so
  # the selftest makes NO real `gh repo view` network calls.
  _seed_cache() { printf '%s\t%s\t%s\n' "$1" "$2" "$(date -u +%s)" >> "$REPO_VISIBILITY_CACHE_FILE"; }
  _seed_cache "fake-public-owner/fake-public-repo"   "public"
  _seed_cache "fake-unknown-owner/fake-unknown-repo" "unknown"
  _seed_cache "fake-private-owner/fake-private-repo" "private"

  TOTAL=0
  PASS=0
  _case() {
    local desc="$1" cmd="$2" expected="$3"
    TOTAL=$((TOTAL + 1))
    local payload
    payload="$(python3 -c 'import json, sys; print(json.dumps({"tool_input": {"command": sys.argv[1]}}))' "$cmd")"
    local rc=0
    printf '%s' "$payload" | bash "${BASH_SOURCE[0]}" >/dev/null 2>/dev/null || rc=$?
    local actual="ALLOW"
    [ "$rc" -eq 2 ] && actual="BLOCK"
    if [ "$actual" = "$expected" ]; then
      PASS=$((PASS + 1))
      printf 'PASS  [%-5s] %s\n' "$expected" "$desc"
    else
      printf 'FAIL  [want=%-5s got=%-5s] %s\n' "$expected" "$actual" "$desc"
      printf '      cmd: %s\n' "$cmd"
    fi
  }

  echo "private_repo_detail_guard.sh selftest:"

  # ── Falsification: PRE-fix behaviour (no candidates seeded) must NOT block ──
  # This must set the HOOK's own environment for the subprocess, not merely
  # appear as text inside the simulated command string (the hook never
  # executes that string — it only parses it) — so it is written directly
  # rather than through _case(). The override path genuinely does not exist,
  # simulating a candidates cache that has never been seeded. This must
  # return an EMPTY list, never trigger a cold rebuild — a rebuild would scan
  # the real ~/docs_gh tree and shell out to `gh repo view` for every repo
  # found, which is exactly the unbounded cost a PreToolUse hook must not be
  # able to trigger inline (found and fixed in repo_visibility.sh's own
  # candidates() while writing this test — JohnGavin/llm#794).
  TOTAL=$((TOTAL + 1))
  payload="$(python3 -c 'import json, sys; print(json.dumps({"tool_input": {"command": sys.argv[1]}}))' \
    'gh issue create --repo fake-public-owner/fake-public-repo --title x --body "mentions test-private-repo-xyz"')"
  rc=0
  printf '%s' "$payload" \
    | REPO_VISIBILITY_CANDIDATES_FILE="$TMP_DIR/never-seeded-candidates.tsv" \
      bash "${BASH_SOURCE[0]}" >/dev/null 2>/dev/null || rc=$?
  if [ "$rc" -eq 0 ]; then
    PASS=$((PASS + 1)); echo "PASS  [ALLOW] no candidate list seeded at all -> ALLOW (falsification control)"
  else
    echo "FAIL  [want=ALLOW got=BLOCK] no candidate list seeded at all -> ALLOW (falsification control)"
  fi

  # ── MUST BLOCK: public target, body mentions the synthetic private repo ────
  _case "public target + body mentions synthetic private repo name -> BLOCK" \
    'gh issue create --repo fake-public-owner/fake-public-repo --title x --body "see test-private-repo-xyz for detail"' \
    "BLOCK"

  _case "public target + title mentions synthetic private repo name -> BLOCK" \
    'gh issue create --repo fake-public-owner/fake-public-repo --title "notes on test-private-repo-xyz" --body "no mention here"' \
    "BLOCK"

  _case "unknown-visibility target still scans (fail-closed) -> BLOCK" \
    'gh pr create --repo fake-unknown-owner/fake-unknown-repo --title x --body "test-private-repo-xyz has more"' \
    "BLOCK"

  # ── MUST ALLOW ───────────────────────────────────────────────────────────
  _case "public target, no mention of any candidate -> ALLOW" \
    'gh issue create --repo fake-public-owner/fake-public-repo --title x --body "nothing sensitive here"' \
    "ALLOW"

  _case "private target -> ALLOW regardless of body content (out of scope)" \
    'gh issue create --repo fake-private-owner/fake-private-repo --title x --body "mentions test-private-repo-xyz"' \
    "ALLOW"

  _case "non-gh command -> ALLOW (fast path, never even parses)" \
    'git -C /repo status' \
    "ALLOW"

  _case "gh pr list (not a publish verb) -> ALLOW" \
    'gh pr list --repo fake-public-owner/fake-public-repo' \
    "ALLOW"

  # ── --body-file CONTENTS are scanned too ────────────────────────────────
  printf 'PR description mentioning test-private-repo-xyz in passing.\n' \
    > "$TMP_DIR/body_with_mention.md"
  printf 'Totally unrelated PR description, nothing to see here.\n' \
    > "$TMP_DIR/body_clean.md"
  _case "--body-file contents mention the synthetic private repo -> BLOCK" \
    "gh pr create --repo fake-public-owner/fake-public-repo --title x --body-file $TMP_DIR/body_with_mention.md" \
    "BLOCK"
  _case "--body-file contents are clean -> ALLOW" \
    "gh pr create --repo fake-public-owner/fake-public-repo --title x --body-file $TMP_DIR/body_clean.md" \
    "ALLOW"

  # ── short-name floor: a hypothetical repo literally named "R" must NOT ────
  # be used as a bare scan term (would false-positive on ordinary prose).
  printf 'r\t%s/fake/r\tprivate\n%s' "$TMP_DIR" "$(cat "$REPO_VISIBILITY_CANDIDATES_FILE")" \
    > "$TMP_DIR/rv_candidates_with_short.tsv"
  REPO_VISIBILITY_CANDIDATES_FILE="$TMP_DIR/rv_candidates_with_short.tsv" \
    _case "a 1-char candidate name is never used as a bare scan term -> ALLOW" \
    'gh issue create --repo fake-public-owner/fake-public-repo --title x --body "this is an R package"' \
    "ALLOW"

  # ── path fragment match (not just bare name) ────────────────────────────
  printf 'longname-fixture\t%s/fake/longname-fixture-path\tlocal_only\n' "$TMP_DIR" \
    > "$TMP_DIR/rv_candidates_path.tsv"
  REPO_VISIBILITY_CANDIDATES_FILE="$TMP_DIR/rv_candidates_path.tsv" \
    _case "an absolute path fragment match blocks even with a different name in body" \
    "gh issue create --repo fake-public-owner/fake-public-repo --title x --body \"see ${TMP_DIR}/fake/longname-fixture-path for detail\"" \
    "BLOCK"

  # ── bypass ───────────────────────────────────────────────────────────────
  _case "bypass command-string prefix allows an otherwise-blocked command" \
    'PRIVATE_DETAIL_GUARD_BYPASS=1 gh issue create --repo fake-public-owner/fake-public-repo --title x --body "mentions test-private-repo-xyz"' \
    "ALLOW"
  _case "bypass token in a non-prefix position does not bypass" \
    'gh issue create --repo fake-public-owner/fake-public-repo --title "PRIVATE_DETAIL_GUARD_BYPASS=1" --body "mentions test-private-repo-xyz"' \
    "BLOCK"

  # ── malformed JSON / empty payload fail-open ────────────────────────────
  TOTAL=$((TOTAL + 1))
  rc=0
  printf 'not json' | bash "${BASH_SOURCE[0]}" >/dev/null 2>/dev/null || rc=$?
  if [ "$rc" -eq 0 ]; then PASS=$((PASS + 1)); echo "PASS  [ALLOW] malformed JSON payload fails open"
  else echo "FAIL  [want=ALLOW got=BLOCK] malformed JSON payload fails open"; fi

  rm -rf "$TMP_DIR"
  echo ""
  echo "selftest: $PASS/$TOTAL PASS"
  [ "$PASS" -eq "$TOTAL" ] && exit 0
  exit 1
fi

# Fail-open on any unexpected error: never wedge a session.
main "$@" || exit 0
