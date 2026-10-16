#!/usr/bin/env bash
# check_artifact_sources.sh -- default-deny gate for data going into an Artifact.
#
# Usage: check_artifact_sources.sh <path>...
#        check_artifact_sources.sh --selftest
#
# Given files about to be embedded in or attached to a claude.ai Artifact,
# exit 0 only if EVERY path matches an entry in the allowlist
# (.claude/state/artifact_publish_allowlist.txt) and NO path matches a hard
# deny pattern. Rule: .claude/rules/default-deny-for-publication.md.
#
# Exit codes (checks-must-distinguish-unknown):
#   0  every path allowlisted, none denied
#   1  at least one path denied or not allowlisted (an empty allowlist
#      therefore makes every path exit 1)
#   2  usage error
#   3  INDETERMINATE: allowlist missing/unreadable/malformed, an allowlist
#      entry matches a deny pattern (configuration error), or a path does not
#      exist. A definite denial (1) outranks an indeterminate path (3).
#
# Env overrides (used by --selftest): ARTIFACT_ALLOWLIST_FILE,
# ARTIFACT_SOURCES_ROOT (base for relative allowlist entries).
#
# NOT wired into any hook or setting; that is a separate owner decision.

SCRIPT="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT")" && pwd -P)"
ROOT="${ARTIFACT_SOURCES_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd -P)}"
ALLOWLIST="${ARTIFACT_ALLOWLIST_FILE:-$ROOT/.claude/state/artifact_publish_allowlist.txt}"

# Hard deny: wins over the allowlist. Input is lowercased by the caller.
is_denied() {
  case "$1" in
    *.duckdb | *.duckdb.* | *prompt* | *reviews.db | *.renviron | *secrets.env | *.claude/logs/*) return 0 ;;
  esac
  return 1
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Resolve to an absolute path, following symlinks (bash 3.2 / no realpath).
resolve() {
  local p="$1" i=0 d t
  while [ -L "$p" ] && [ "$i" -lt 10 ]; do
    t="$(readlink "$p")"
    case "$t" in /*) p="$t" ;; *) p="$(dirname "$p")/$t" ;; esac
    i=$((i + 1))
  done
  if [ -d "$p" ]; then (cd "$p" && pwd -P); return; fi
  d="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)" || return 1
  printf '%s/%s\n' "$d" "$(basename "$p")"
}

expand_entry() {
  case "$1" in
    "~/"*) printf '%s\n' "$HOME/${1#\~/}" ;;
    /*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "$ROOT/$1" ;;
  esac
}

run_check() {
  if [ "$#" -lt 1 ]; then
    echo "usage: check_artifact_sources.sh <path>... | --selftest" >&2
    return 2
  fi
  if [ ! -r "$ALLOWLIST" ] || [ ! -f "$ALLOWLIST" ]; then
    echo "INDETERMINATE: allowlist missing or unreadable: $ALLOWLIST" >&2
    return 3
  fi

  # Parse the allowlist into entries (bash 3.2: no mapfile).
  local entries=() line src dt reason n_entries=0 cfg_err=0 lsrc
  local tab=$'\t'
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "" | "#"*) continue ;; esac
    IFS="$tab" read -r src dt reason <<EOF
$line
EOF
    if [ -z "$src" ] || [ -z "$reason" ] || ! printf '%s' "$dt" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
      echo "INDETERMINATE: malformed allowlist entry (need source<TAB>YYYY-MM-DD<TAB>reason): $line" >&2
      cfg_err=1
      continue
    fi
    lsrc="$(lower "$src")"
    if is_denied "$lsrc"; then
      echo "INDETERMINATE: allowlist entry matches a hard deny pattern (configuration error): $src" >&2
      cfg_err=1
      continue
    fi
    case "$src" in
      "*" | "**" | "/" | "/*" | "~" | "~/*" | "./*")
        echo "INDETERMINATE: allowlist entry is too broad (configuration error): $src" >&2
        cfg_err=1
        continue
        ;;
    esac
    entries+=("$(expand_entry "$src")")
    n_entries=$((n_entries + 1))
  done <"$ALLOWLIST"
  [ "$cfg_err" -eq 1 ] && return 3

  local p abs lraw labs e ok denied=0 notallowed=0 indet=0
  for p in "$@"; do
    lraw="$(lower "$p")"
    if is_denied "$lraw"; then
      echo "DENIED (hard deny pattern): $p" >&2
      denied=1
      continue
    fi
    if [ ! -e "$p" ] && [ ! -L "$p" ]; then
      echo "INDETERMINATE: path does not exist: $p" >&2
      indet=1
      continue
    fi
    abs="$(resolve "$p")" || {
      echo "INDETERMINATE: cannot resolve: $p" >&2
      indet=1
      continue
    }
    labs="$(lower "$abs")"
    if is_denied "$labs"; then
      echo "DENIED (hard deny pattern after resolving symlinks): $p -> $abs" >&2
      denied=1
      continue
    fi
    ok=0
    for e in ${entries[@]+"${entries[@]}"}; do
      # shellcheck disable=SC2254  # unquoted on purpose: entry is a glob
      case "$abs" in $e) ok=1 ;; esac
      [ "$ok" -eq 1 ] && break
    done
    if [ "$ok" -eq 0 ]; then
      echo "DENIED (not on allowlist): $p" >&2
      notallowed=1
    fi
  done

  if [ "$denied" -eq 1 ] || [ "$notallowed" -eq 1 ]; then return 1; fi
  if [ "$indet" -eq 1 ]; then return 3; fi
  # Unreachable with an empty allowlist: every existing path hit "not on
  # allowlist" above, so no pass is ever printed for default-deny.
  echo "OK: $# path(s) allowlisted ($n_entries allowlist entr$([ "$n_entries" -eq 1 ] && echo y || echo ies))"
  return 0
}

# ---------------------------------------------------------------- selftest
selftest() {
  local T pass=0 fail=0 rc out
  T="$(mktemp -d "${TMPDIR:-/tmp}/artsrc.XXXXXX")" || { echo "mktemp failed" >&2; return 3; }
  T="$(cd "$T" && pwd -P)"
  mkdir -p "$T/data" "$T/.claude/logs" "$T/root"
  printf 'a,b\n1,2\n' >"$T/data/ok.csv"
  printf 'a,b\n1,2\n' >"$T/data/other.csv"
  printf 'x\n' >"$T/data/session_prompts.csv"
  printf 'x\n' >"$T/data/unified.duckdb"
  printf 'x\n' >"$T/data/reviews.db"
  printf 'x\n' >"$T/data/.Renviron"
  printf 'x\n' >"$T/.claude/logs/hook.log"
  ln -s "$T/data/unified.duckdb" "$T/data/innocent.csv"
  local tab=$'\t'
  local AL_EMPTY="$T/al_empty.txt" AL_OK="$T/al_ok.txt" AL_BAD="$T/al_bad.txt"
  printf '# header only\n' >"$AL_EMPTY"
  printf '# hdr\n%s\n%s\n%s\n' \
    "$T/data/ok.csv${tab}2026-10-14${tab}selftest" \
    "$T/data/*${tab}2026-10-14${tab}selftest glob (deny must still win)" \
    "$T/.claude/*${tab}2026-10-14${tab}selftest glob covering logs" >"$AL_OK"
  printf '%s\n' "$T/data/prompt_stats.csv${tab}2026-10-14${tab}bad entry" >"$AL_BAD"

  # expect <name> <want-rc> <allowlist> <script> <args...>
  expect() {
    local name="$1" want="$2" al="$3" scr="$4"
    shift 4
    out="$(ARTIFACT_ALLOWLIST_FILE="$al" ARTIFACT_SOURCES_ROOT="$T/root" bash "$scr" "$@" 2>&1)"
    rc=$?
    if [ "$rc" -eq "$want" ]; then
      pass=$((pass + 1)); echo "PASS  $name (rc=$rc)"
    else
      fail=$((fail + 1)); echo "FAIL  $name (want rc=$want, got rc=$rc): $out"
    fi
    LAST_OUT="$out"
  }

  expect "empty allowlist denies an existing file" 1 "$AL_EMPTY" "$SCRIPT" "$T/data/ok.csv"
  case "$LAST_OUT" in *OK:*) fail=$((fail + 1)); echo "FAIL  empty allowlist printed a pass: $LAST_OUT" ;;
    *) pass=$((pass + 1)); echo "PASS  empty allowlist never prints a pass" ;; esac
  expect "allowlisted file passes" 0 "$AL_OK" "$SCRIPT" "$T/data/ok.csv"
  expect "allowlisted via glob passes" 0 "$AL_OK" "$SCRIPT" "$T/data/other.csv"
  expect "not-allowlisted file denied" 1 "$AL_OK" "$SCRIPT" "$AL_EMPTY"
  expect "mixed: one allowlisted, one not" 1 "$AL_OK" "$SCRIPT" "$T/data/ok.csv" "$AL_EMPTY"
  expect "deny wins: prompt file under allowlisted glob" 1 "$AL_OK" "$SCRIPT" "$T/data/session_prompts.csv"
  expect "deny wins: .duckdb under allowlisted glob" 1 "$AL_OK" "$SCRIPT" "$T/data/unified.duckdb"
  expect "deny wins: reviews.db under allowlisted glob" 1 "$AL_OK" "$SCRIPT" "$T/data/reviews.db"
  expect "deny wins: .Renviron under allowlisted glob" 1 "$AL_OK" "$SCRIPT" "$T/data/.Renviron"
  expect "deny wins: .claude/logs under allowlisted glob" 1 "$AL_OK" "$SCRIPT" "$T/.claude/logs/hook.log"
  expect "deny wins: innocent-named symlink to a duckdb" 1 "$AL_OK" "$SCRIPT" "$T/data/innocent.csv"
  expect "allowlist entry matching a deny pattern is a config error (3)" 3 "$AL_BAD" "$SCRIPT" "$T/data/ok.csv"
  case "$LAST_OUT" in *prompt_stats.csv*) pass=$((pass + 1)); echo "PASS  config error names the entry" ;;
    *) fail=$((fail + 1)); echo "FAIL  config error does not name the entry: $LAST_OUT" ;; esac
  expect "missing allowlist is INDETERMINATE (3)" 3 "$T/no_such_allowlist.txt" "$SCRIPT" "$T/data/ok.csv"
  expect "nonexistent path is INDETERMINATE (3)" 3 "$AL_OK" "$SCRIPT" "$T/data/missing_file.csv"
  expect "no arguments is a usage error (2)" 2 "$AL_OK" "$SCRIPT"

  # Falsification: each mutant must make a guarded case go wrong, proving the
  # case above can fail. Mutant 1: checker always exits 0. Mutant 2: hard deny
  # disabled. Mutant 3: allowlist match always succeeds.
  local M1="$T/mut_always0.sh" M2="$T/mut_nodeny.sh" M3="$T/mut_allmatch.sh"
  sed '1a\
exit 0' "$SCRIPT" >"$M1"
  sed 's/^is_denied() {$/is_denied() { return 1/' "$SCRIPT" >"$M2"
  sed 's/case "\$abs" in \$e) ok=1 ;; esac/ok=1/' "$SCRIPT" >"$M3"
  falsify() { # name, mutant, allowlist, want-real-rc, args...
    local name="$1" mut="$2" al="$3" want="$4"
    shift 4
    if cmp -s "$mut" "$SCRIPT"; then
      fail=$((fail + 1)); echo "FAIL  falsify $name: mutation did not change the script"; return
    fi
    out="$(ARTIFACT_ALLOWLIST_FILE="$al" ARTIFACT_SOURCES_ROOT="$T/root" bash "$mut" "$@" 2>&1)"
    rc=$?
    if [ "$rc" -ne "$want" ]; then
      pass=$((pass + 1)); echo "PASS  falsified: $name (mutant rc=$rc, real checker gives $want)"
    else
      fail=$((fail + 1)); echo "FAIL  falsify $name: mutant still returned rc=$rc, so the case cannot go red"
    fi
  }
  falsify "always-exit-0 vs denied duckdb" "$M1" "$AL_OK" 1 "$T/data/unified.duckdb"
  falsify "always-exit-0 vs empty allowlist" "$M1" "$AL_EMPTY" 1 "$T/data/ok.csv"
  falsify "deny disabled vs prompt file" "$M2" "$AL_OK" 1 "$T/data/session_prompts.csv"
  falsify "deny disabled vs symlink to duckdb" "$M2" "$AL_OK" 1 "$T/data/innocent.csv"
  falsify "allowlist match always true vs unlisted file" "$M3" "$AL_OK" 1 "$AL_EMPTY"

  rm -rf "$T"
  echo "RESULT: $pass passed, $fail failed"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi
run_check "$@"
exit $?
