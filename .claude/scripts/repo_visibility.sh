#!/usr/bin/env bash
#
# repo_visibility.sh — classify a repo as one of:
#   public | private | local_only | confidential_by_policy | unknown
#
# JohnGavin/llm#794 item 1 ("the missing mechanism: a visibility registry").
#
# Usage:
#   repo_visibility.sh classify <path-or-owner/repo>
#   repo_visibility.sh candidates [--refresh]
#   repo_visibility.sh --selftest
#
# ─── Policy (read this before changing return values) ───────────────────────
# "Anything not affirmatively resolved as `public` is treated as private."
# This script itself returns a genuine `unknown` value, distinct from both
# `public` and `private`, whenever it cannot determine visibility (gh
# missing/unauthenticated, network error, ambiguous or nonexistent repo,
# timeout). Per the `checks-must-distinguish-unknown` rule, a lookup failure
# must never read as "public" — that decision belongs to the CALLER (e.g.
# private_repo_detail_guard.sh), which treats anything other than an
# affirmative `public` as non-publishable-detail-safe. This script does not
# collapse `unknown` into `private` itself, so a caller with a different
# risk tolerance can still distinguish "confirmed private" from "could not
# tell".
#
# ─── Classification sources, in priority order ──────────────────────────────
#   1. A repo-local `PRIVATE` marker file at the repo root — the same
#      author-declared-sensitivity convention the knowledge hub already uses
#      (~/docs_gh/llm/knowledge/PRIVATE, see the `wiki-conventions` rule).
#      -> confidential_by_policy
#   2. This repo's OWN confidential-by-policy list
#      (.claude/state/confidential-repos.txt by default) — matched by
#      directory basename or `owner/repo` string. This is llm's own list,
#      analogous in spirit to llmtelemetry::excluded_dashboard_projects()
#      but not a dependency on it: this hook protects llm's own publish
#      actions and must not require llmtelemetry (a separate R package) to
#      be installed/loadable from a bash hook.
#      -> confidential_by_policy
#   3. No git remote at all -> local_only (strictly private, never
#      publishable).
#   4. `gh repo view OWNER/REPO --json visibility` -> public or private.
#      Any failure -> unknown.
#
# ─── Cache ───────────────────────────────────────────────────────────────────
# Flat TSV at $REPO_VISIBILITY_CACHE_FILE (default
# ~/.claude/logs/repo_visibility_cache.tsv): one row per classified key,
# `key<TAB>visibility<TAB>epoch`. TTL $REPO_VISIBILITY_CACHE_TTL seconds
# (default 300 — a few minutes, per the issue's "pick something reasonable"
# instruction; overridable for testing). REPO_VISIBILITY_NO_CACHE=1 forces a
# fresh lookup on every call.
#
# The `candidates` list (enumeration of repos under
# $REPO_VISIBILITY_SCAN_ROOT, default ~/docs_gh) is a SEPARATE, much more
# expensive operation — one `gh repo view` per repo found — cached
# separately at $REPO_VISIBILITY_CANDIDATES_FILE with its own, much longer
# TTL ($REPO_VISIBILITY_CANDIDATES_TTL, default 86400 = 1 day). A
# PreToolUse hook MUST NOT trigger a cold rebuild of this list inline (it
# would blow any reasonable hook timeout scanning ~100+ repos over the
# network) — `candidates` without --refresh returns whatever is cached, even
# if stale, and returns EMPTY (never a hang) if nothing has been cached yet.
# Seed the cache once with `repo_visibility.sh candidates --refresh`.
#
# Self-test: bash repo_visibility.sh --selftest

set -uo pipefail

# Resolve relative to THIS script's own location (not a hardcoded
# ~/.claude/... path) — .claude/scripts/ is a symlink into the main checkout
# in production, so a hardcoded path would silently point at the main
# checkout's copy even under worktree-isolated testing. Same rationale as
# CRED_PATTERNS_LIB_DIR in secret_leak_guard.sh.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# All config derives from env vars via a function, not one-shot top-level
# assignment, so that a caller (including the self-test below) can `export`
# an override AFTER sourcing/starting this script and have it take effect by
# re-calling _load_config — a plain `VAR="${ENV_VAR:-default}"` assignment at
# script-start would freeze the OLD value even if the env var changes later
# in the same process, which is exactly the trap the self-test below is
# written to avoid falling into silently.
_load_config() {
  CONFIDENTIAL_LIST="${REPO_VISIBILITY_CONFIDENTIAL_LIST:-$SCRIPT_DIR/../state/confidential-repos.txt}"
  CACHE_FILE="${REPO_VISIBILITY_CACHE_FILE:-$HOME/.claude/logs/repo_visibility_cache.tsv}"
  CACHE_TTL="${REPO_VISIBILITY_CACHE_TTL:-300}"
  CANDIDATES_FILE="${REPO_VISIBILITY_CANDIDATES_FILE:-$HOME/.claude/logs/repo_visibility_candidates_cache.tsv}"
  CANDIDATES_TTL="${REPO_VISIBILITY_CANDIDATES_TTL:-86400}"
  SCAN_ROOT="${REPO_VISIBILITY_SCAN_ROOT:-$HOME/docs_gh}"
  GH_TIMEOUT="${GH_REPO_VISIBILITY_TIMEOUT:-8}"
  MAX_CANDIDATES_SCAN="${REPO_VISIBILITY_MAX_CANDIDATES_SCAN:-500}"
}
_load_config

_now() { date -u +%s; }

# ─── single-value cache (classify) ──────────────────────────────────────────
_cache_get() {
  local key="$1"
  [ "${REPO_VISIBILITY_NO_CACHE:-0}" = "1" ] && return 1
  [ -f "$CACHE_FILE" ] || return 1
  local line ts_now; ts_now="$(_now)"
  # Last matching row wins (a rewrite appends rather than in-place-edits).
  line="$(grep -F "$(printf '%s\t' "$key")" "$CACHE_FILE" 2>/dev/null | tail -1)"
  [ -n "$line" ] || return 1
  local val epoch
  val="$(printf '%s' "$line" | cut -f2)"
  epoch="$(printf '%s' "$line" | cut -f3)"
  [ -n "$val" ] && [ -n "$epoch" ] || return 1
  if [ $(( ts_now - epoch )) -le "$CACHE_TTL" ]; then
    printf '%s' "$val"
    return 0
  fi
  return 1
}

_cache_put() {
  local key="$1" val="$2"
  mkdir -p "$(dirname "$CACHE_FILE")" 2>/dev/null || true
  printf '%s\t%s\t%s\n' "$key" "$val" "$(_now)" >> "$CACHE_FILE" 2>/dev/null || true
}

# ─── helpers ─────────────────────────────────────────────────────────────────

_has_private_marker() {
  # $1 = absolute repo root path
  [ -f "$1/PRIVATE" ]
}

_trim() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}

_in_confidential_list() {
  # $1 = basename (may be empty), $2 = owner/repo (may be empty)
  local basename_val="$1" ownerrepo_val="$2" line entry
  [ -f "$CONFIDENTIAL_LIST" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    entry="${line%%#*}"
    entry="$(_trim "$entry")"
    [ -z "$entry" ] && continue
    if [ -n "$basename_val" ] && [ "$entry" = "$basename_val" ]; then
      return 0
    fi
    if [ -n "$ownerrepo_val" ] && [ "$entry" = "$ownerrepo_val" ]; then
      return 0
    fi
  done < "$CONFIDENTIAL_LIST"
  return 1
}

_owner_repo_from_remote() {
  # $1 = remote URL (ssh or https). Prints "owner/repo" on stdout and
  # returns 0, or returns 1 if this is not a recognisable github.com remote.
  local url="$1" rest owner repo
  case "$url" in
    *github.com*) : ;;
    *) return 1 ;;
  esac
  rest="${url#*github.com:}"
  rest="${rest#*github.com/}"
  rest="${rest%/}"
  rest="${rest%.git}"
  [ "$rest" = "$url" ] && return 1   # neither prefix form matched
  owner="${rest%%/*}"
  repo="${rest#*/}"
  [ -n "$owner" ] && [ -n "$repo" ] && [ "$owner" != "$rest" ] || return 1
  case "$repo" in */*) return 1 ;; esac   # more than one extra path segment: unsupported shape
  printf '%s/%s' "$owner" "$repo"
}

_gh_visibility() {
  # $1 = owner/repo. Prints public|private|unknown.
  local ownerrepo="$1" vis rc
  vis="$(timeout "$GH_TIMEOUT" gh repo view "$ownerrepo" --json visibility -q '.visibility' 2>/dev/null)"
  rc=$?
  if [ $rc -ne 0 ] || [ -z "$vis" ]; then
    printf 'unknown'
    return
  fi
  case "$vis" in
    PUBLIC) printf 'public' ;;
    PRIVATE) printf 'private' ;;
    *) printf 'unknown' ;;
  esac
}

# ─── classify_one <path-or-owner/repo> ──────────────────────────────────────
# Prints exactly one of: public private local_only confidential_by_policy unknown
classify_one() {
  local input="$1" abs_path="" basename_val="" ownerrepo="" remote="" key="" cached result

  if [ -d "$input" ]; then
    abs_path="$(cd "$input" && pwd)"
    basename_val="$(basename "$abs_path")"
  fi

  # Cache key: prefer the resolved absolute path (stable identity for local
  # repos); fall back to the raw input string (for bare owner/repo lookups
  # with no local checkout).
  key="${abs_path:-$input}"
  if cached="$(_cache_get "$key")"; then
    printf '%s\n' "$cached"
    return 0
  fi

  if [ -n "$abs_path" ]; then
    if _has_private_marker "$abs_path"; then
      result="confidential_by_policy"
      _cache_put "$key" "$result"
      printf '%s\n' "$result"
      return 0
    fi
    remote="$(git -C "$abs_path" remote get-url origin 2>/dev/null || true)"
    if [ -n "$remote" ]; then
      ownerrepo="$(_owner_repo_from_remote "$remote" || true)"
    fi
    if _in_confidential_list "$basename_val" "$ownerrepo"; then
      result="confidential_by_policy"
      _cache_put "$key" "$result"
      printf '%s\n' "$result"
      return 0
    fi
    if [ -z "$remote" ]; then
      result="local_only"
      _cache_put "$key" "$result"
      printf '%s\n' "$result"
      return 0
    fi
    if [ -z "$ownerrepo" ]; then
      # Has a remote, but not a github.com shape we can verify via gh.
      result="unknown"
      _cache_put "$key" "$result"
      printf '%s\n' "$result"
      return 0
    fi
  else
    # Bare name input (no local directory) — e.g. "owner/repo" or a plain
    # repo name with no path component.
    ownerrepo="$input"
    case "$ownerrepo" in */*) : ;; *) ownerrepo="" ;; esac
    if _in_confidential_list "$input" "$ownerrepo"; then
      result="confidential_by_policy"
      _cache_put "$key" "$result"
      printf '%s\n' "$result"
      return 0
    fi
    if [ -z "$ownerrepo" ]; then
      result="unknown"
      _cache_put "$key" "$result"
      printf '%s\n' "$result"
      return 0
    fi
  fi

  result="$(_gh_visibility "$ownerrepo")"
  _cache_put "$key" "$result"
  printf '%s\n' "$result"
}

# ─── candidates [--refresh] ─────────────────────────────────────────────────
# Prints TSV: name<TAB>path<TAB>visibility for every repo under $SCAN_ROOT
# classified private, local_only, or confidential_by_policy. NEVER rebuilds
# inline unless --refresh is passed or no cache file exists at all (first
# run) — a PreToolUse hook consuming this must stay fast.
_build_candidates() {
  local d name vis count=0
  : > "${CANDIDATES_FILE}.tmp"
  while IFS= read -r d; do
    [ -e "$d/.git" ] || continue
    case "$(basename "$d")" in
      .*|worktrees) continue ;;
    esac
    count=$((count + 1))
    if [ "$count" -gt "$MAX_CANDIDATES_SCAN" ]; then
      break
    fi
    name="$(basename "$d")"
    vis="$(classify_one "$d")"
    case "$vis" in
      private|local_only|confidential_by_policy)
        printf '%s\t%s\t%s\n' "$name" "$d" "$vis" >> "${CANDIDATES_FILE}.tmp"
        ;;
    esac
  done < <(find "$SCAN_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
  mv "${CANDIDATES_FILE}.tmp" "$CANDIDATES_FILE"
  printf '%s\n' "$(_now)" > "${CANDIDATES_FILE}.epoch"
}

candidates() {
  # CRITICAL: this function must NEVER trigger a cold rebuild except on an
  # explicit --refresh. A PreToolUse hook calls this on every gh issue/pr
  # publish command; a first-run auto-build would scan every repo under
  # $SCAN_ROOT and shell out to `gh repo view` for each one, which cannot
  # complete inside any reasonable hook timeout. Earlier revision of this
  # function auto-built on a missing cache file — found and fixed while
  # writing private_repo_detail_guard.sh's own self-test, which hit exactly
  # this cost when it tried to simulate an unseeded cache (JohnGavin/llm#794).
  local refresh="${1:-}" epoch ts_now out rc
  mkdir -p "$(dirname "$CANDIDATES_FILE")" 2>/dev/null || true
  if [ "$refresh" = "--refresh" ]; then
    _build_candidates
  fi

  if [ ! -f "$CANDIDATES_FILE" ]; then
    # Distinguishable NEGATIVE result: legitimately nothing cached yet (a
    # fresh install, or --refresh itself failed to write the file). Empty
    # stdout here is a real, correct answer ("no candidates known"), not a
    # failure to determine one — the stderr line is what makes that call
    # auditable rather than silent (checks-must-distinguish-unknown).
    echo "repo_visibility.sh: candidates cache has never been seeded — run 'repo_visibility.sh candidates --refresh' once (this call returns an empty list, NOT a rebuild)" >&2
    return 0
  fi

  # Stale-but-present cache is still returned (never block on a rebuild);
  # only warn on stderr so a human can decide to refresh.
  ts_now="$(_now)"
  epoch="$(cat "${CANDIDATES_FILE}.epoch" 2>/dev/null || echo 0)"
  if [ $(( ts_now - epoch )) -gt "$CANDIDATES_TTL" ]; then
    echo "repo_visibility.sh: candidates cache is stale (>${CANDIDATES_TTL}s) — run 'repo_visibility.sh candidates --refresh' when convenient" >&2
  fi

  # INDETERMINATE result: the cache file exists but could not be read (I/O
  # error, permission denied, etc). This is NOT the same as "no candidates"
  # above — empty output here would silently disable the pre-publish scan
  # for a reason a caller cannot distinguish from a legitimately-empty
  # cache, which is exactly the failure mode checks-must-distinguish-unknown
  # exists to catch. Capture the exit status and branch on it rather than
  # swallowing it into `|| true`.
  out="$(cat "$CANDIDATES_FILE" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "repo_visibility.sh: INDETERMINATE — candidates cache exists but could not be read ($CANDIDATES_FILE): $out" >&2
    return 2
  fi
  printf '%s\n' "$out"
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# SELF-TEST
# ═══════════════════════════════════════════════════════════════════════════
if [ "${1:-}" = "--selftest" ]; then
  TMP_DIR="$(mktemp -d /tmp/repo_visibility_selftest_XXXXXX)"
  export REPO_VISIBILITY_CACHE_FILE="$TMP_DIR/cache.tsv"
  export REPO_VISIBILITY_CANDIDATES_FILE="$TMP_DIR/candidates.tsv"
  export REPO_VISIBILITY_CONFIDENTIAL_LIST="$TMP_DIR/confidential-repos.txt"
  export REPO_VISIBILITY_NO_CACHE=1
  _load_config   # re-derive CACHE_FILE/CANDIDATES_FILE/CONFIDENTIAL_LIST from the exports above

  TOTAL=0
  PASS=0
  _case() {
    local desc="$1" got="$2" want="$3"
    TOTAL=$((TOTAL + 1))
    if [ "$got" = "$want" ]; then
      PASS=$((PASS + 1))
      printf 'PASS  [%-25s] %s\n' "$want" "$desc"
    else
      printf 'FAIL  [want=%-15s got=%-15s] %s\n' "$want" "$got" "$desc"
    fi
  }

  echo "repo_visibility.sh selftest:"

  # ── local_only: a fresh git init, no remote ─────────────────────────────
  mkdir -p "$TMP_DIR/local_only_repo"
  (cd "$TMP_DIR/local_only_repo" && git init -q 2>/dev/null)
  _case "no-remote local repo -> local_only" \
    "$(classify_one "$TMP_DIR/local_only_repo")" "local_only"

  # ── confidential_by_policy: repo-local PRIVATE marker ───────────────────
  mkdir -p "$TMP_DIR/marker_repo"
  (cd "$TMP_DIR/marker_repo" && git init -q 2>/dev/null)
  touch "$TMP_DIR/marker_repo/PRIVATE"
  _case "PRIVATE marker file -> confidential_by_policy" \
    "$(classify_one "$TMP_DIR/marker_repo")" "confidential_by_policy"

  # ── confidential_by_policy: matched by the confidential-repos list ──────
  mkdir -p "$TMP_DIR/policy_repo"
  (cd "$TMP_DIR/policy_repo" && git init -q 2>/dev/null)
  echo "policy_repo" > "$REPO_VISIBILITY_CONFIDENTIAL_LIST"
  _case "confidential-repos.txt basename match -> confidential_by_policy" \
    "$(classify_one "$TMP_DIR/policy_repo")" "confidential_by_policy"
  : > "$REPO_VISIBILITY_CONFIDENTIAL_LIST"   # reset for later cases

  # ── unknown: non-github remote we cannot verify ─────────────────────────
  mkdir -p "$TMP_DIR/nongithub_repo"
  (cd "$TMP_DIR/nongithub_repo" && git init -q 2>/dev/null && git remote add origin https://gitlab.example.com/owner/repo.git 2>/dev/null)
  _case "non-github.com remote -> unknown (cannot verify)" \
    "$(classify_one "$TMP_DIR/nongithub_repo")" "unknown"

  # ── unknown: fail-closed on a bare name gh cannot resolve ───────────────
  _case "nonexistent owner/repo -> unknown, NOT public (fail-closed)" \
    "$(GH_REPO_VISIBILITY_TIMEOUT=5 classify_one "definitely-not-a-real-owner-xyz/definitely-not-a-real-repo-xyz")" \
    "unknown"

  # ── unknown must never equal public, under a simulated auth failure ─────
  _case "invalid GH_TOKEN -> unknown, NOT public (fail-closed)" \
    "$(GH_TOKEN=invalid-token-value GH_REPO_VISIBILITY_TIMEOUT=5 classify_one "JohnGavin/llm")" \
    "unknown"

  # ── owner/repo URL parsing (unit-level, via a fake remote + no gh call) ──
  mkdir -p "$TMP_DIR/parse_ssh_repo"
  (cd "$TMP_DIR/parse_ssh_repo" && git init -q 2>/dev/null && git remote add origin git@github.com:JohnGavin/llm.git 2>/dev/null)
  _case "ssh remote form parses to a resolvable owner/repo (gh calls out, real answer varies by auth state, so only assert it is NOT local_only/confidential_by_policy)" \
    "$(case "$(GH_REPO_VISIBILITY_TIMEOUT=5 classify_one "$TMP_DIR/parse_ssh_repo")" in local_only|confidential_by_policy) echo FAIL_WRONG_BUCKET ;; *) echo OK ;; esac)" \
    "OK"

  # ── candidates: never rebuilds inline without --refresh once cache exists ──
  printf 'fake_repo\t/tmp/fake_repo\tprivate\n' > "$REPO_VISIBILITY_CANDIDATES_FILE"
  echo 1 > "${REPO_VISIBILITY_CANDIDATES_FILE}.epoch"
  _case "candidates without --refresh returns the existing cache verbatim" \
    "$(candidates)" \
    "$(printf 'fake_repo\t/tmp/fake_repo\tprivate')"

  # ── candidates on a NEVER-SEEDED cache must return empty, NOT rebuild ────
  # A rebuild here would scan $SCAN_ROOT for real and shell out to
  # `gh repo view` per repo — the exact cost a PreToolUse hook consuming this
  # must never trigger inline. Regression case for a bug this self-test
  # caught: an earlier revision auto-built on ANY missing file, only
  # skipping the rebuild once one had already been written once before.
  export REPO_VISIBILITY_CANDIDATES_FILE="$TMP_DIR/never-seeded.tsv"
  _load_config
  never_seeded_out="$(candidates 2>/dev/null)"
  _case "candidates on a cache that was never seeded returns empty, no rebuild" \
    "$never_seeded_out" ""
  _case "the never-seeded path really was never created by the call above" \
    "$([ -f "$TMP_DIR/never-seeded.tsv" ] && echo EXISTS || echo ABSENT)" \
    "ABSENT"
  export REPO_VISIBILITY_CANDIDATES_FILE="$TMP_DIR/candidates.tsv"
  _load_config

  # ── cache TTL behaviour ──────────────────────────────────────────────────
  unset REPO_VISIBILITY_NO_CACHE
  export REPO_VISIBILITY_CACHE_TTL=3600
  _load_config
  : > "$REPO_VISIBILITY_CACHE_FILE"
  mkdir -p "$TMP_DIR/cache_repo"
  (cd "$TMP_DIR/cache_repo" && git init -q 2>/dev/null)
  first="$(classify_one "$TMP_DIR/cache_repo")"
  # Corrupt the underlying repo state (git dir removed) — if the SECOND call
  # still returns the same value without re-touching the filesystem check,
  # the cache is doing its job (a fresh lookup on a repo with no .git at all
  # would still resolve to local_only by coincidence here, so instead prove
  # the cache row exists and its value matches).
  cached_row="$(grep -F "$TMP_DIR/cache_repo" "$REPO_VISIBILITY_CACHE_FILE" | tail -1 | cut -f2)"
  _case "a classify_one call writes a cache row with the same value" \
    "$cached_row" "$first"
  export REPO_VISIBILITY_NO_CACHE=1

  rm -rf "$TMP_DIR"
  echo ""
  echo "selftest: $PASS/$TOTAL PASS"
  [ "$PASS" -eq "$TOTAL" ] && exit 0
  exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════
# CLI dispatch
# ═══════════════════════════════════════════════════════════════════════════
case "${1:-}" in
  classify)
    [ -n "${2:-}" ] || { echo "usage: repo_visibility.sh classify <path-or-owner/repo>" >&2; exit 2; }
    classify_one "$2"
    ;;
  candidates)
    candidates "${2:-}"
    ;;
  *)
    echo "usage: repo_visibility.sh classify <path-or-owner/repo> | candidates [--refresh] | --selftest" >&2
    exit 2
    ;;
esac
