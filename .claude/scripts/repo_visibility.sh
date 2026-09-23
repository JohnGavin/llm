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
#   2. This repo's OWN confidential-by-policy list, drawn from TWO sources —
#      matched by directory basename or `owner/repo` string:
#        a) the TRACKED, public file (.claude/state/confidential-repos.txt by
#           default) — for names that are already public knowledge or
#           synthetic (e.g. the canary), safe to commit to a public repo.
#        b) a LOCAL, never-committed overlay
#           ($REPO_VISIBILITY_CONFIDENTIAL_LOCAL_LIST, default
#           ~/.config/confidential-repos.local.txt) — for the REAL names a
#           human has decided must never be published. Committing a real
#           confidential name to the tracked file — even inside a guard
#           whose whole purpose is protecting such names — defeats the
#           guard by publishing exactly what it exists to protect
#           (roborev #10301). The overlay is machine-local, mode 600,
#           gitignored by construction (it never lives inside any repo).
#      Both sources share one parser (`_confidential_entries`) so they can
#      never drift in how comments/blank-lines/trimming are handled. This is
#      llm's own list, analogous in spirit to
#      llmtelemetry::excluded_dashboard_projects() but not a dependency on
#      it: this hook protects llm's own publish actions and must not require
#      llmtelemetry (a separate R package) to be installed/loadable from a
#      bash hook.
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
# The `candidates` list (declared entries, above, PLUS filesystem discovery
# under $REPO_VISIBILITY_SCAN_ROOTS — a colon-separated list of roots,
# default $REPO_VISIBILITY_SCAN_ROOT or ~/docs_gh if neither is set) is a
# SEPARATE, much more expensive operation — one `gh repo view` per
# discovered repo — cached separately at $REPO_VISIBILITY_CANDIDATES_FILE
# with its own, much longer TTL ($REPO_VISIBILITY_CANDIDATES_TTL, default
# 86400 = 1 day). A PreToolUse hook MUST NOT trigger a cold rebuild of this
# list inline (it would blow any reasonable hook timeout scanning ~100+
# repos over the network) — `candidates` without --refresh returns whatever
# is cached, and NEVER rebuilds inline.
#
# Filesystem discovery finds repo ROOTS ONLY, by locating `.git` (directory
# or, for a `git worktree`, file) up to $REPO_VISIBILITY_SCAN_DEPTH
# directories below each root (default 6) — never a flat depth-1 children
# list. A scan root is NOT flat: `~/docs_gh/worktrees/<project>/<branch>/`
# is itself a repo three-plus levels down, and a depth-1 sweep missed it
# entirely (llm#1183). Discovery only enumerates directory NAMES via
# `find -name .git -prune` — it never opens or reads file content, so
# widening it does not create a new information-leak surface.
#
# `candidates` exit codes (checks-must-distinguish-unknown /
# exit-code-conventions): 0 = usable result, stdout carries the list (which
# may legitimately be empty — a fresh, current cache that found nothing is
# a real negative). 3 = INDETERMINATE — the cache was never seeded, is past
# its TTL, or could not be read; stdout may still carry stale content for a
# human to read, but a caller MUST treat exit 3 as "could not check", never
# as "nothing found", and act accordingly (private_repo_detail_guard.sh
# blocks the publish verb it guards on exit 3 — llm#1183 fix 2). Seed the
# cache once with `repo_visibility.sh candidates --refresh`.
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
  # Local, never-committed overlay for REAL declared confidential names —
  # see the "Classification sources" comment above (roborev #10301). Missing
  # is the normal case (fresh machine); present-but-unreadable is a genuine
  # unknown and warns rather than silently contributing nothing — see
  # _confidential_entries().
  CONFIDENTIAL_LOCAL_LIST="${REPO_VISIBILITY_CONFIDENTIAL_LOCAL_LIST:-$HOME/.config/confidential-repos.local.txt}"
  CACHE_FILE="${REPO_VISIBILITY_CACHE_FILE:-$HOME/.claude/logs/repo_visibility_cache.tsv}"
  CACHE_TTL="${REPO_VISIBILITY_CACHE_TTL:-300}"
  CANDIDATES_FILE="${REPO_VISIBILITY_CANDIDATES_FILE:-$HOME/.claude/logs/repo_visibility_candidates_cache.tsv}"
  CANDIDATES_TTL="${REPO_VISIBILITY_CANDIDATES_TTL:-86400}"
  # SCAN_ROOTS: colon-separated list of directories to search for repo
  # roots (PATH-style separator). REPO_VISIBILITY_SCAN_ROOTS (new, multi-root)
  # takes priority; REPO_VISIBILITY_SCAN_ROOT (singular, pre-#1183) is kept
  # as a back-compat single-root override for existing callers/tests that
  # only ever set one; default is $HOME/docs_gh if neither is set.
  SCAN_ROOTS="${REPO_VISIBILITY_SCAN_ROOTS:-${REPO_VISIBILITY_SCAN_ROOT:-$HOME/docs_gh}}"
  # Depth (in directories) below each scan root at which a repo's `.git`
  # may be found. Not flat: worktrees nest as
  # <root>/worktrees/<project>/<branch>/.git — depth 3-4 depending on
  # whether the branch name itself contains a "/". Bounded so this never
  # turns into an unbounded walk of a deep vendor tree (llm#1183).
  SCAN_DEPTH="${REPO_VISIBILITY_SCAN_DEPTH:-6}"
  GH_TIMEOUT="${GH_REPO_VISIBILITY_TIMEOUT:-8}"
  MAX_CANDIDATES_SCAN="${REPO_VISIBILITY_MAX_CANDIDATES_SCAN:-500}"
  # Concurrency guard for _build_candidates()'s final publish step (llm
  # repo_visibility-refresh-race fix, 2026-09-22) — see that function's
  # comment for the full race this defends against. A lock held longer than
  # this is treated as abandoned (its holder was killed mid-refresh) rather
  # than blocking every future refresh forever. WAIT_SECS bounds how long a
  # concurrent refresh will queue behind another before giving up.
  CANDIDATES_LOCK_STALE_SECS="${REPO_VISIBILITY_LOCK_STALE_SECS:-60}"
  CANDIDATES_LOCK_WAIT_SECS="${REPO_VISIBILITY_LOCK_WAIT_SECS:-30}"
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

_confidential_entries() {
  # Single parser for BOTH confidential-name sources — the TRACKED, public
  # list ($CONFIDENTIAL_LIST) and the LOCAL, never-committed overlay
  # ($CONFIDENTIAL_LOCAL_LIST). Emits one trimmed, comment-stripped,
  # non-blank entry per line. Both readers of confidential names
  # (_in_confidential_list below and the declared-entries block in
  # _build_candidates) call this so the comment/trim/skip-blank rules can
  # never drift between them (roborev #10301).
  #
  # A source file that does not exist is the normal case (nothing declared
  # there yet, or a fresh machine with no local overlay) and contributes no
  # entries — silently, on purpose.
  #
  # A source file that EXISTS but could not be read (permissions, I/O
  # error) is a genuine UNKNOWN, not the same as "nothing declared" — per
  # checks-must-distinguish-unknown, that must never collapse silently into
  # an empty list. This function still returns 0 and contributes nothing
  # from that file (existing callers' exit codes/behaviour are unchanged),
  # but prints a one-line warning to stderr so the gap is auditable rather
  # than silent.
  local f line entry
  for f in "$CONFIDENTIAL_LIST" "$CONFIDENTIAL_LOCAL_LIST"; do
    [ -n "$f" ] || continue
    [ -e "$f" ] || continue
    if [ ! -r "$f" ]; then
      echo "repo_visibility.sh: WARNING — confidential list exists but is not readable, contributing NO entries from it: $f" >&2
      continue
    fi
    while IFS= read -r line || [ -n "$line" ]; do
      entry="${line%%#*}"
      entry="$(_trim "$entry")"
      [ -z "$entry" ] && continue
      printf '%s\n' "$entry"
    done < "$f"
  done
}

_in_confidential_list() {
  # $1 = basename (may be empty), $2 = owner/repo (may be empty)
  local basename_val="$1" ownerrepo_val="$2" entry
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    if [ -n "$basename_val" ] && [ "$entry" = "$basename_val" ]; then
      return 0
    fi
    if [ -n "$ownerrepo_val" ] && [ "$entry" = "$ownerrepo_val" ]; then
      return 0
    fi
  done < <(_confidential_entries)
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

# ─── candidates refresh lock ────────────────────────────────────────────────
# Serializes the final "publish" step of _build_candidates() (the mv into
# place + the .epoch stamp) across concurrent `candidates --refresh`
# invocations — see that function's own comment for the race this fixes.
#
# Prefers flock(1) (atomic, kernel-arbitrated, no polling) when present.
# Falls back to an mkdir-based lock (mkdir is atomic on any POSIX
# filesystem) when flock is unavailable. Correction, 2026-09-23: an earlier
# version of this comment claimed "flock is absent on this machine" as a
# fact about the hardware -- that was measured from a shell that had NOT
# entered the mandatory nix dev shell (`~/docs_gh/llm/default.sh` /
# `nix-agent-shell-protocol`), where PATH lacks the nix-provided toybox
# package. Re-verified: `nix-shell ~/docs_gh/llm/default.nix --run "command
# -v flock"` DOES find flock (via toybox) on this same machine. The
# mkdir-based fallback stays -- this script (invoked by
# private_repo_detail_guard.sh, a PreToolUse hook) may legitimately run
# outside any nix-entered shell, and the fallback needs to be correct
# regardless -- but its existence should not be justified by a false claim
# about flock's general availability here.
#
# A lock older than CANDIDATES_LOCK_STALE_SECS is treated as abandoned (its
# holder was killed mid-refresh) and reclaimed rather than blocking every
# future refresh forever.
#
# Uses a FIXED numeric file descriptor (200), never bash 4's `{varname}fd`
# auto-allocation syntax — macOS ships bash 3.2 (GPLv2-frozen, verified
# still the version at /bin/bash on this machine) as its system bash, and
# `exec {fd}>...` is a bash-4.1+ feature that fails outright under it. A
# fixed numeric fd works unchanged back to bash's earliest versions
# (verified against both /bin/bash 3.2.57 and the newer bash on $PATH here).
_acquire_candidates_lock() {
  mkdir -p "$(dirname "$CANDIDATES_FILE")" 2>/dev/null || true
  if command -v flock >/dev/null 2>&1; then
    exec 200>"${CANDIDATES_FILE}.flock" 2>/dev/null || return 1
    flock -w "$CANDIDATES_LOCK_WAIT_SECS" 200
    return $?
  fi

  local lock_dir="${CANDIDATES_FILE}.lock" waited=0 lock_mtime lock_age
  local max_waits=$(( CANDIDATES_LOCK_WAIT_SECS * 5 ))   # polls every 0.2s
  while ! mkdir "$lock_dir" 2>/dev/null; do
    if [ -d "$lock_dir" ]; then
      lock_mtime="$(stat -f %m "$lock_dir" 2>/dev/null || stat -c %Y "$lock_dir" 2>/dev/null || echo 0)"
      lock_age=$(( $(_now) - lock_mtime ))
      if [ "$lock_age" -gt "$CANDIDATES_LOCK_STALE_SECS" ]; then
        # Abandoned lock (holder crashed/was killed mid-refresh) — reclaim
        # it rather than waiting out the full timeout below every time.
        rmdir "$lock_dir" 2>/dev/null
        continue
      fi
    fi
    waited=$((waited + 1))
    if [ "$waited" -gt "$max_waits" ]; then
      return 1
    fi
    sleep 0.2
  done
  return 0
}

_release_candidates_lock() {
  if command -v flock >/dev/null 2>&1; then
    flock -u 200 2>/dev/null || true
    exec 200>&- 2>/dev/null || true
    return 0
  fi
  rmdir "${CANDIDATES_FILE}.lock" 2>/dev/null || true
}

# ─── candidates [--refresh] ─────────────────────────────────────────────────
# Prints TSV: name<TAB>path<TAB>visibility for every repo under $SCAN_ROOT
# classified private, local_only, or confidential_by_policy. NEVER rebuilds
# inline unless --refresh is passed or no cache file exists at all (first
# run) — a PreToolUse hook consuming this must stay fast.
#
# ── Concurrency (fix, 2026-09-22) ───────────────────────────────────────────
# Two concurrent `candidates --refresh` invocations (a scheduled background
# refresh overlapping a manual one, or two sessions both publishing at once)
# used to race on a FIXED shared "${CANDIDATES_FILE}.tmp" path: one
# process's `: > tmp` could truncate the OTHER process's in-progress tmp
# file mid-write, the losing process's final `mv` could fail outright, and
# — critically — the function's LAST line stamped a FRESH .epoch
# unconditionally, regardless of whether the `mv` before it had succeeded,
# silently masking the failure (`set -uo pipefail`, no `-e`, so the
# function's own return status became the unconditional printf's). Net
# effect: a losing/corrupting refresh could leave the real cache file
# severely truncated while ALSO stamping a fresh .epoch — so the staleness
# check in candidates() below would report the corrupted, truncated cache as
# current. Found while investigating a private_repo_detail_guard.sh false
# clear during crypto_swarms work; reproduced with 3 concurrent
# `--refresh` calls against ~30 fake repos (candidates.tsv row counts across
# 5 trials: 90, 2, 1, 1, 90 — 90 is the correct/expected count).
#
# Fixed two ways, together:
#   1. Every invocation accumulates into its OWN uniquely-named tmp file
#      (mktemp), so no concurrent writer can ever truncate or interleave
#      into another writer's in-progress output. This alone removes the
#      data-loss hazard.
#   2. The final publish step (rename into place + .epoch stamp) is
#      serialized under a lock (_acquire_candidates_lock /
#      _release_candidates_lock, above), so two racing refreshes cannot
#      leave the rename and the epoch stamp as two separate, non-atomic
#      events observable half-applied by a concurrent reader, and a failed
#      rename is propagated as a real error rather than swallowed by the
#      unconditional epoch write that used to follow it unconditionally.
_build_candidates() {
  local d name vis count=0 entry root gitdir tmp_file lock_rc
  tmp_file="$(mktemp "${CANDIDATES_FILE}.XXXXXX" 2>/dev/null)" || {
    echo "repo_visibility.sh: ERROR — could not create a temp file for candidates rebuild (mktemp failed near $CANDIDATES_FILE)" >&2
    return 1
  }
  # Cleanup is explicit at each return path below (rm -f "$tmp_file" on the
  # two failure paths; the mv on success already removes it), rather than a
  # `trap ... RETURN` — deliberately. A RETURN trap set here does NOT fire
  # only once for this function's own return: bash re-fires it again when
  # this function's CALLER (candidates()) subsequently returns, by which
  # point $tmp_file is out of scope. Under `set -u`, that second firing's
  # `rm -f "$tmp_file"` throws an unbound-variable error, and because it
  # fires from inside candidates()'s own return (called by the self-test as
  # `candidates --refresh >/dev/null 2>&1`), the error is silently
  # swallowed by that redirection and the ENTIRE script exits — no output,
  # no diagnostic. Reproduced and confirmed in isolation while writing this
  # fix (a trap-based version of this exact structure kills the process
  # silently; the same structure without the trap does not). Explicit
  # per-path cleanup has no such caller-leakage hazard.

  # ── Declared entries first (llm#1183), from BOTH confidential sources ──────
  # Every entry from _confidential_entries — the TRACKED, public list
  # ($CONFIDENTIAL_LIST) AND the LOCAL, never-committed overlay
  # ($CONFIDENTIAL_LOCAL_LIST) — becomes a candidate in its own right, with an
  # EMPTY path field, regardless of whether that repo exists under
  # $SCAN_ROOT, exists on this machine at all, or is currently checked out.
  #
  # Why this exists: the discovery loop below can only classify directories it
  # has already found, so a repo outside $SCAN_ROOT was unprotectable — adding
  # it to the confidential list changed nothing, because the list only
  # influences how an ALREADY-ENUMERATED directory is classified. That gap hid
  # a confidential, local-only repo from the pre-publish guard entirely
  # (llm#1183). Declaration is now sufficient on its own; filesystem discovery
  # below is the safety net for repos nobody remembered to declare, not the
  # primary mechanism.
  #
  # Why a REAL declared name must go in the overlay, not the tracked file:
  # a name declared here specifically because it must never be published —
  # committed to a PUBLIC, tracked file — publishes exactly that name to
  # every reader of this public repo, defeating the guard it exists to feed
  # (roborev #10301). The tracked file is for names that are already public
  # or synthetic (the canary); real confidential names live only in
  # $CONFIDENTIAL_LOCAL_LIST (mode 600, never committed, never inside any
  # repo).
  #
  # The empty path field is load-bearing: private_repo_detail_guard.sh reads it
  # as "declared, not discovered" and matches such names at ANY length, where a
  # discovered name must clear MIN_NAME_LEN. See that hook's name-length note.
  #
  # A name that is BOTH declared and discovered legitimately produces two rows
  # (one name-only, one with a path). That is harmless -- the guard breaks on
  # first match -- and the path row adds a genuinely distinct match target.
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    printf '%s\t%s\t%s\n' "$entry" "" "confidential_by_policy" >> "$tmp_file"
  done < <(_confidential_entries)

  # ── Filesystem discovery (safety net) ─────────────────────────────────────
  # Repo roots are found by locating `.git` (directory for an ordinary
  # checkout, FILE for a `git worktree`) up to $SCAN_DEPTH directories below
  # EACH of $SCAN_ROOTS (colon-separated) — NOT by assuming repos are flat
  # immediate children of a single root. A flat -maxdepth 1 sweep of a
  # single root missed real repos nested inside the scanned tree (worktrees)
  # AND missed repos outside the tree entirely (llm#1183).
  #
  # `-name .git -print -type d -prune`: for every match, print first (so a
  # `.git` FILE — a worktree — is captured even though `-type d` is false
  # for it), then prune only when it IS a directory, so find never descends
  # into a real .git object store. This enumerates directory/file NAMES
  # only; it never opens or reads content, so widening this scan does not
  # create a new information-leak surface.
  local IFS_saved="$IFS"
  IFS=':'
  local -a _scan_roots_arr
  read -r -a _scan_roots_arr <<< "$SCAN_ROOTS"
  IFS="$IFS_saved"
  for root in "${_scan_roots_arr[@]}"; do
    [ -n "$root" ] || continue
    [ -d "$root" ] || continue
    while IFS= read -r gitdir; do
      [ -n "$gitdir" ] || continue
      d="${gitdir%/.git}"
      case "$(basename "$d")" in
        .*) continue ;;
      esac
      count=$((count + 1))
      if [ "$count" -gt "$MAX_CANDIDATES_SCAN" ]; then
        break 2
      fi
      name="$(basename "$d")"
      vis="$(classify_one "$d")"
      case "$vis" in
        private|local_only|confidential_by_policy)
          printf '%s\t%s\t%s\n' "$name" "$d" "$vis" >> "$tmp_file"
          ;;
      esac
    done < <(find "$root" -mindepth 1 -maxdepth "$SCAN_DEPTH" -name .git -print -type d -prune 2>/dev/null)
  done

  # ── Serialize the final publish (rename + epoch stamp) under a lock ──────
  # By this point $tmp_file is this invocation's own complete, internally
  # consistent result — the mktemp fix above already prevents any other
  # writer from having corrupted it. The lock additionally orders WHICH
  # writer's result becomes the final $CANDIDATES_FILE, so a slow writer
  # that started earlier can never overwrite a faster writer's fresher
  # result with its own older one.
  if ! _acquire_candidates_lock; then
    echo "repo_visibility.sh: ERROR — could not acquire the candidates refresh lock within ${CANDIDATES_LOCK_WAIT_SECS}s (another refresh appears stuck); leaving $CANDIDATES_FILE untouched" >&2
    rm -f "$tmp_file"
    return 1
  fi
  if mv "$tmp_file" "$CANDIDATES_FILE" 2>/dev/null; then
    printf '%s\n' "$(_now)" > "${CANDIDATES_FILE}.epoch"
    lock_rc=0
  else
    echo "repo_visibility.sh: ERROR — mv of refreshed candidates into place failed; NOT stamping .epoch (a stale/missing .epoch correctly reports INDETERMINATE rather than lying about freshness)" >&2
    rm -f "$tmp_file"
    lock_rc=1
  fi
  _release_candidates_lock
  return "$lock_rc"
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
  # Exit codes (checks-must-distinguish-unknown / exit-code-conventions):
  #   0 = usable result. stdout carries the candidate list, which may be
  #       legitimately empty (a fresh, current cache that genuinely found
  #       nothing is a real negative, not an unknown).
  #   3 = INDETERMINATE. The list could not be established — never seeded,
  #       past its TTL, or unreadable. stdout may still carry stale content
  #       (for a human debugging), but a caller MUST NOT read that as "safe
  #       to allow" — private_repo_detail_guard.sh blocks the publish verb
  #       it guards on exit 3 rather than silently allowing (llm#1183 fix 2:
  #       an empty-because-broken cache was previously indistinguishable
  #       from an empty-because-nothing-found one, and both silently
  #       allowed).
  local refresh="${1:-}" epoch ts_now out rc stale=0 build_rc=0
  mkdir -p "$(dirname "$CANDIDATES_FILE")" 2>/dev/null || true
  if [ "$refresh" = "--refresh" ]; then
    _build_candidates
    build_rc=$?
    if [ "$build_rc" -ne 0 ]; then
      # Per checks-must-distinguish-unknown: a refresh that silently failed
      # to update the cache must not be indistinguishable from one that
      # succeeded. _build_candidates already reported the specific cause to
      # stderr; do NOT invent a new exit code here — fall through to
      # whatever is currently on disk (a still-fresh previous cache, a
      # stale one, or none at all), which the existing checks below already
      # classify correctly and report as exit 3 INDETERMINATE whenever the
      # data on disk cannot be trusted as current.
      echo "repo_visibility.sh: WARNING — candidates --refresh failed to update the cache (see error above); falling through to whatever is currently on disk" >&2
    fi
  fi

  if [ ! -f "$CANDIDATES_FILE" ]; then
    # INDETERMINATE, not a negative: the cache has never been seeded, so
    # "found nothing" and "never looked" are indistinguishable from stdout
    # alone. Prior behaviour treated this the same as a genuine empty
    # result (exit 0); that is exactly the collapse
    # checks-must-distinguish-unknown forbids, and it is what left the
    # pre-publish guard inert whenever nobody had run `candidates
    # --refresh` yet (llm#1183). NEVER trigger a rebuild here — only an
    # explicit --refresh may do that.
    echo "repo_visibility.sh: INDETERMINATE — candidates cache has never been seeded — run 'repo_visibility.sh candidates --refresh' once (this call returns no usable result, NOT a rebuild)" >&2
    return 3
  fi

  # Stale-but-present cache: still returned on stdout (never block on an
  # inline rebuild, and a human debugging wants to see the stale content),
  # but the exit code reports INDETERMINATE — a cache this old may be
  # missing repos created or reclassified since the last refresh, so a
  # caller must not treat it as a confirmed-current negative (llm#1183
  # fix 2).
  ts_now="$(_now)"
  epoch="$(cat "${CANDIDATES_FILE}.epoch" 2>/dev/null || echo 0)"
  if [ $(( ts_now - epoch )) -gt "$CANDIDATES_TTL" ]; then
    stale=1
    echo "repo_visibility.sh: INDETERMINATE — candidates cache is stale (>${CANDIDATES_TTL}s) — run 'repo_visibility.sh candidates --refresh'" >&2
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
    return 3
  fi
  printf '%s\n' "$out"
  [ "$stale" -eq 1 ] && return 3
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
  # Nonexistent path under $TMP_DIR throughout — this selftest MUST NEVER
  # read the real ~/.config overlay (which may hold a genuine confidential
  # name on this machine). Re-exported to a fresh nonexistent path at every
  # section below that also swaps CONFIDENTIAL_LIST/SCAN_ROOT, so no section
  # depends on this one line staying unmodified elsewhere in the file.
  export REPO_VISIBILITY_CONFIDENTIAL_LOCAL_LIST="$TMP_DIR/overlay_unused_0.txt"
  export REPO_VISIBILITY_NO_CACHE=1
  _load_config   # re-derive CACHE_FILE/CANDIDATES_FILE/CONFIDENTIAL_LIST/CONFIDENTIAL_LOCAL_LIST from the exports above

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
  date -u +%s > "${REPO_VISIBILITY_CANDIDATES_FILE}.epoch"   # FRESH
  candidates_out="$(candidates)"; candidates_rc=$?
  _case "candidates without --refresh returns the existing cache verbatim" \
    "$candidates_out" \
    "$(printf 'fake_repo\t/tmp/fake_repo\tprivate')"
  _case "a FRESH cache with content exits 0 (usable), not 3 (llm#1183 fix 2)" \
    "$candidates_rc" "0"

  # ── a STALE cache (llm#1183 fix 2): content is still returned on stdout
  # (a human debugging wants to see it), but the exit code must distinguish
  # this from a fresh, current answer — a caller reading only stdout (as
  # private_repo_detail_guard.sh did before this fix) cannot tell a day-old
  # cache from a fresh one; the exit code is what makes that distinguishable.
  echo 1 > "${REPO_VISIBILITY_CANDIDATES_FILE}.epoch"   # STALE (epoch~1970)
  candidates_out="$(candidates 2>/dev/null)"; candidates_rc=$?
  _case "a STALE cache still returns its content on stdout" \
    "$candidates_out" \
    "$(printf 'fake_repo\t/tmp/fake_repo\tprivate')"
  _case "a STALE cache exits 3 (INDETERMINATE), not 0 (llm#1183 fix 2)" \
    "$candidates_rc" "3"

  # ── candidates on a NEVER-SEEDED cache must return empty, NOT rebuild ────
  # A rebuild here would scan $SCAN_ROOT for real and shell out to
  # `gh repo view` per repo — the exact cost a PreToolUse hook consuming this
  # must never trigger inline. Regression case for a bug this self-test
  # caught: an earlier revision auto-built on ANY missing file, only
  # skipping the rebuild once one had already been written once before.
  export REPO_VISIBILITY_CANDIDATES_FILE="$TMP_DIR/never-seeded.tsv"
  export REPO_VISIBILITY_CONFIDENTIAL_LOCAL_LIST="$TMP_DIR/overlay_unused_1.txt"
  _load_config
  never_seeded_out="$(candidates 2>/dev/null)"; never_seeded_rc=$?
  _case "candidates on a cache that was never seeded returns empty, no rebuild" \
    "$never_seeded_out" ""
  _case "candidates on a cache that was never seeded exits 3, not 0 (llm#1183 fix 2)" \
    "$never_seeded_rc" "3"
  _case "the never-seeded path really was never created by the call above" \
    "$([ -f "$TMP_DIR/never-seeded.tsv" ] && echo EXISTS || echo ABSENT)" \
    "ABSENT"
  export REPO_VISIBILITY_CANDIDATES_FILE="$TMP_DIR/candidates.tsv"
  export REPO_VISIBILITY_CONFIDENTIAL_LOCAL_LIST="$TMP_DIR/overlay_unused_2.txt"
  _load_config

  # ── declared entries become candidates without existing on disk (llm#1183) ─
  # The defect this covers: _build_candidates could only ever emit repos it
  # found under $SCAN_ROOT, so a repo living outside that tree was invisible to
  # the pre-publish guard no matter what confidential-repos.txt said. A
  # confidential local-only repo sat unprotected because of it.
  #
  # $SCAN_ROOT is pointed at an EMPTY directory here, so nothing can be
  # discovered and the only possible source of output is the declared list.
  export REPO_VISIBILITY_SCAN_ROOT="$TMP_DIR/empty_scan_root"
  export REPO_VISIBILITY_CANDIDATES_FILE="$TMP_DIR/declared_candidates.tsv"
  export REPO_VISIBILITY_CONFIDENTIAL_LIST="$TMP_DIR/declared_list.txt"
  export REPO_VISIBILITY_CONFIDENTIAL_LOCAL_LIST="$TMP_DIR/overlay_unused_3.txt"
  mkdir -p "$TMP_DIR/empty_scan_root"
  printf '# a comment\n\nnowhere-on-this-disk   # trailing comment\n' \
    > "$TMP_DIR/declared_list.txt"
  _load_config
  candidates --refresh >/dev/null 2>&1
  _case "a declared repo that exists nowhere on disk is still a candidate" \
    "$(candidates 2>/dev/null)" \
    "$(printf 'nowhere-on-this-disk\t\tconfidential_by_policy')"

  # Falsification: with the declared list empty, the SAME call must produce
  # nothing. Without this, the case above would still pass if _build_candidates
  # had simply started emitting a constant.
  : > "$TMP_DIR/declared_list.txt"
  candidates --refresh >/dev/null 2>&1
  empty_fresh_out="$(candidates 2>/dev/null)"; empty_fresh_rc=$?
  _case "with nothing declared, an empty scan root yields no candidates" \
    "$empty_fresh_out" ""
  _case "a FRESH cache that is genuinely empty exits 0, not 3 (real negative, not unknown; llm#1183 fix 2)" \
    "$empty_fresh_rc" "0"

  # ── overlay-only declared entries (roborev #10301 fix) ──────────────────
  # A REAL confidential name must never sit in the TRACKED, public list — it
  # belongs only in the local, never-committed overlay
  # ($CONFIDENTIAL_LOCAL_LIST). Prove the overlay alone (tracked list empty,
  # scan root empty) is a sufficient source for BOTH the candidates builder
  # and the classify_one() policy match — the two readers _confidential_entries
  # feeds. Synthetic fixture name only; a real declared name is never typed
  # into this codebase.
  export REPO_VISIBILITY_CANDIDATES_FILE="$TMP_DIR/overlay_candidates.tsv"
  export REPO_VISIBILITY_CONFIDENTIAL_LOCAL_LIST="$TMP_DIR/overlay_list.txt"
  # $REPO_VISIBILITY_CONFIDENTIAL_LIST (the tracked list) is still empty from
  # the falsification step above.
  printf 'zzz-local-overlay-fixture   # synthetic selftest fixture, never a real repo\n' \
    > "$TMP_DIR/overlay_list.txt"
  _load_config
  candidates --refresh >/dev/null 2>&1
  _case "(a) an overlay-only entry becomes a declared candidate row" \
    "$(candidates 2>/dev/null)" \
    "$(printf 'zzz-local-overlay-fixture\t\tconfidential_by_policy')"

  mkdir -p "$TMP_DIR/zzz-local-overlay-fixture"
  (cd "$TMP_DIR/zzz-local-overlay-fixture" && git init -q 2>/dev/null)
  _case "(b) an overlay-only entry is classified confidential_by_policy via classify_one" \
    "$(classify_one "$TMP_DIR/zzz-local-overlay-fixture")" "confidential_by_policy"

  # (c) Falsification: remove the overlay entirely. The SAME candidates
  # rebuild and the SAME classify_one call on the SAME path must now report
  # nothing / not-confidential — proving (a) and (b) actually depended on the
  # overlay file, not on a stale cache row or a hardcoded true. NO_CACHE is
  # still 1 here (unset happens further below), so classify_one re-checks
  # rather than replaying its earlier cached answer.
  rm -f "$TMP_DIR/overlay_list.txt"
  candidates --refresh >/dev/null 2>&1
  _case "(c) falsification: overlay removed -> candidates yields nothing from it" \
    "$(candidates 2>/dev/null)" ""
  _case "(c) falsification: overlay removed -> classify_one no longer confidential_by_policy" \
    "$(classify_one "$TMP_DIR/zzz-local-overlay-fixture")" "local_only"

  # ── filesystem discovery: multiple roots + nested depth (llm#1183 fix 1) ──
  # The defect was TWO separate assumptions baked into one flat sweep:
  #   (a) only ONE root was ever scanned — a repo outside it was invisible
  #       no matter what;
  #   (b) only depth-1 CHILDREN of that root were scanned — a repo nested a
  #       few levels down, the shape every `git worktree` actually takes
  #       ($root/worktrees/<project>/<branch>/), was invisible even though
  #       it sits inside the tree supposedly being scanned.
  # Four fixtures isolate (a) from (b) rather than conflating them:
  #   flat-repo-fixture     under root_a, depth 1  -- control: proves the
  #                          scan of root_a itself still runs.
  #   nested-repo-fixture   under root_a, depth 3  -- isolates defect (b)
  #                          alone (same root a flat sweep already covers).
  #   second-root-repo-fixture under root_b, depth 1 -- isolates defect (a)
  #                          alone (a second root, but not nested).
  #   branchA (git WORKTREE) under root_b, depth 4, `.git` is a FILE -- both
  #                          defects at once, the actual real-world shape.
  root_a="$TMP_DIR/scan_root_a"
  root_b="$TMP_DIR/scan_root_b"
  mkdir -p "$root_a/flat-repo-fixture"
  (cd "$root_a/flat-repo-fixture" && git init -q 2>/dev/null)
  mkdir -p "$root_a/nested/sublevel/nested-repo-fixture"
  (cd "$root_a/nested/sublevel/nested-repo-fixture" && git init -q 2>/dev/null)
  mkdir -p "$root_b/second-root-repo-fixture"
  (cd "$root_b/second-root-repo-fixture" && git init -q 2>/dev/null)
  mkdir -p "$root_b/worktree-main-fixture"
  (cd "$root_b/worktree-main-fixture" && git init -q 2>/dev/null)
  (cd "$root_b/worktree-main-fixture" && git worktree add "$root_b/worktrees/proj/branchA" -b selftest-branch-a >/dev/null 2>&1)
  unset REPO_VISIBILITY_SCAN_ROOT
  export REPO_VISIBILITY_SCAN_ROOTS="$root_a:$root_b"
  export REPO_VISIBILITY_CANDIDATES_FILE="$TMP_DIR/multi_root_candidates.tsv"
  export REPO_VISIBILITY_CONFIDENTIAL_LIST="$TMP_DIR/multi_root_confidential.txt"
  export REPO_VISIBILITY_CONFIDENTIAL_LOCAL_LIST="$TMP_DIR/overlay_unused_multi.txt"
  : > "$TMP_DIR/multi_root_confidential.txt"
  _load_config
  candidates --refresh >/dev/null 2>&1
  multi_out="$(candidates 2>/dev/null)"
  _case "(control) a flat depth-1 repo under the first root is still discovered" \
    "$(printf '%s' "$multi_out" | grep -c 'flat-repo-fixture')" "1"
  _case "a repo NESTED below the top level of a scanned root is discovered (defect b alone)" \
    "$(printf '%s' "$multi_out" | grep -c 'nested-repo-fixture')" "1"
  _case "a repo that exists only under a SECOND scan root is discovered (defect a alone)" \
    "$(printf '%s' "$multi_out" | grep -c 'second-root-repo-fixture')" "1"
  _case "a nested git WORKTREE (.git is a FILE) under a second root is discovered (both defects)" \
    "$(printf '%s' "$multi_out" | grep -c 'branchA')" "1"

  # Falsification: shrink SCAN_DEPTH so it can still reach the shallow repos
  # (.git at depth <=2) but not the nested ones (.git at depth >=3), and
  # confirm they drop out of the SAME rebuild — proves the cases above
  # actually exercise depth-bounded discovery, not a `find` default.
  export REPO_VISIBILITY_SCAN_DEPTH=2
  _load_config
  candidates --refresh >/dev/null 2>&1
  shallow_out="$(candidates 2>/dev/null)"
  _case "(falsification) a shallower depth still finds the flat repos (control: the scan itself still ran)" \
    "$(printf '%s' "$shallow_out" | grep -c -e 'flat-repo-fixture' -e 'second-root-repo-fixture')" "2"
  _case "(falsification) a shallower depth misses the nested repo on the SAME root again" \
    "$(printf '%s' "$shallow_out" | grep -c 'nested-repo-fixture')" "0"
  _case "(falsification) a shallower depth misses the nested worktree again" \
    "$(printf '%s' "$shallow_out" | grep -c 'branchA')" "0"
  unset REPO_VISIBILITY_SCAN_DEPTH
  unset REPO_VISIBILITY_SCAN_ROOTS

  # ── concurrency: overlapping --refresh invocations never corrupt the
  #    cache (regression case for the refresh-race fix, 2026-09-22) ────────
  # _build_candidates() used to write into a FIXED shared
  # "${CANDIDATES_FILE}.tmp" path, so two concurrent `candidates --refresh`
  # calls could truncate each other's in-progress output, race the final
  # mv, and still stamp a FRESH .epoch regardless — silently reporting a
  # corrupted, truncated cache as current. Forcing the exact interleaving
  # deterministically (rather than by timing luck) is not attempted here;
  # this is instead a best-effort concurrent-trial test. It is nonetheless
  # a meaningful regression check under the fix: mktemp + the publish lock
  # make the OUTCOME deterministic regardless of scheduling (every
  # concurrent writer produces a complete, uncorrupted result and only one
  # of them "wins" the final rename), so a passing run here is evidence of
  # correctness, not a lucky non-reproduction — unlike on the pre-fix code,
  # where the same test reliably produced mv errors and/or a truncated
  # cache on every run during manual verification of this fix.
  concurrency_root="$TMP_DIR/concurrency_scan_root"
  mkdir -p "$concurrency_root"
  for _i in $(seq 1 15); do
    mkdir -p "$concurrency_root/repo_$_i/.git"
  done
  export REPO_VISIBILITY_SCAN_ROOTS="$concurrency_root"
  unset REPO_VISIBILITY_SCAN_ROOT
  export REPO_VISIBILITY_CANDIDATES_FILE="$TMP_DIR/concurrency_candidates.tsv"
  export REPO_VISIBILITY_CONFIDENTIAL_LIST="$TMP_DIR/concurrency_confidential.txt"
  export REPO_VISIBILITY_CONFIDENTIAL_LOCAL_LIST="$TMP_DIR/overlay_unused_concurrency.txt"
  : > "$REPO_VISIBILITY_CONFIDENTIAL_LIST"
  _load_config
  concurrency_err="$TMP_DIR/concurrency_stderr.txt"
  : > "$concurrency_err"
  for _c in 1 2 3; do
    ( candidates --refresh >/dev/null 2>>"$concurrency_err" ) &
  done
  wait
  concurrency_rows="$(wc -l < "$REPO_VISIBILITY_CANDIDATES_FILE" 2>/dev/null | tr -d ' ')"
  concurrency_mv_errors="$(grep -c 'No such file or directory' "$concurrency_err" 2>/dev/null)"
  [ -n "$concurrency_mv_errors" ] || concurrency_mv_errors=0
  _case "concurrent --refresh invocations: no 'mv: ... No such file' on stderr" \
    "$concurrency_mv_errors" "0"
  _case "concurrent --refresh invocations: candidates.tsv has all 15 rows, not truncated" \
    "$concurrency_rows" "15"
  unset REPO_VISIBILITY_SCAN_ROOTS

  unset REPO_VISIBILITY_SCAN_ROOT
  export REPO_VISIBILITY_CONFIDENTIAL_LIST="$TMP_DIR/confidential-repos.txt"
  export REPO_VISIBILITY_CANDIDATES_FILE="$TMP_DIR/candidates.tsv"
  export REPO_VISIBILITY_CONFIDENTIAL_LOCAL_LIST="$TMP_DIR/overlay_unused_4.txt"
  _load_config

  # ── cache TTL behaviour ──────────────────────────────────────────────────
  unset REPO_VISIBILITY_NO_CACHE
  export REPO_VISIBILITY_CACHE_TTL=3600
  export REPO_VISIBILITY_CONFIDENTIAL_LOCAL_LIST="$TMP_DIR/overlay_unused_5.txt"
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
