#!/usr/bin/env bash
# secrets_cache_regen.sh — regenerate ~/.config/secrets.env from Bitwarden
# Secrets Manager (BWS), the system of record.
#
# Run at login and after every rotation in BWS. See
# .claude/rules/secrets-single-source.md for the architecture.
#
# Usage:
#   secrets_cache_regen.sh [--dry-run|--apply] [--cache-file <path>]
#   secrets_cache_regen.sh --selftest
#
# --dry-run     Default. Fetches and validates; makes no writes.
# --apply       Installs the validated fetch as the new cache.
# --cache-file  Override the default ~/.config/secrets.env path.
# --selftest    Run built-in tests against fixture data only. Never
#               invokes the real `bws` binary.
#
# Refuses to install if: the fetch failed or is empty; the fetch has fewer
# keys than the current cache and --allow-removals was not given (a
# truncated fetch must never silently shrink the cache; --allow-removals
# is for a deliberate deletion, and shows exactly which keys before
# proceeding -- see the removal guard in _main, llm#1024/llm#945); any line
# is malformed; or any line appears to contain two NAME= assignments glued
# together (the exact corruption previously caused by a missing trailing
# newline on an append).
#
# The installed cache is intentionally plaintext (mode 600): it is not the
# system of record, it is fully regenerable from BWS at any time. Report
# output (counts, names) never includes a raw secret value — the installed
# FILE legitimately contains values, since storing them is the file's
# entire purpose.
#
# Tracked in JohnGavin/llm (secrets single-source-of-truth migration).

set -uo pipefail

export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

BWS_BIN="${BWS_BIN:-bws}"
CACHE_FILE="${CACHE_FILE:-$HOME/.config/secrets.env}"

# ── Pure / directly-testable functions ──────────────────────────────────

_bws_fetch_env() {
  # Live call — only reached outside --selftest.
  "$BWS_BIN" secret list -o env
}

_count_keys() {
  # Counts NAME=VALUE / export NAME=VALUE lines, ignoring blank/comment
  # lines. A malformed "glued" line still counts as one line here — the
  # malformed-line scan in _validate_fetch is what actually catches it.
  local file="$1"
  [ -r "$file" ] || {
    echo 0
    return 0
  }
  grep -cE '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=' "$file" 2>/dev/null || echo 0
}

_key_names() {
  local file="$1"
  [ -r "$file" ] || return 0
  grep -E '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=' "$file" 2>/dev/null |
    sed -E 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/'
}

_validate_fetch() {
  # $1 = path to a freshly-fetched candidate file
  # $2 = path to the current cache (may not exist)
  # Prints a report to stdout (names/counts only, never a raw value) and
  # returns 0 if the candidate is safe to install, 1 if it must be
  # refused.
  local candidate="$1" current="$2"

  if [ ! -s "$candidate" ]; then
    echo "REFUSE: fetch produced an empty or missing file"
    return 1
  fi

  # Malformed-line / glued-two-assignments scan. Only key NAMES are ever
  # printed in the diagnostic — never the line's raw value content. The
  # "second assignment" heuristic looks for an UPPER_SNAKE_CASE token
  # (our own secret-naming convention, length >= 4) immediately followed
  # by "=" appearing after the first assignment; this avoids false
  # positives on values that legitimately contain "=" (e.g. base64
  # padding), since real secret values here are not themselves
  # upper-snake-case tokens.
  local bad
  bad="$(awk '
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/ { next }
    {
      line = $0
      sub(/^[[:space:]]*export[[:space:]]+/, "", line)
      if (line !~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
        print NR": malformed line (does not start with NAME=)"
        next
      }
      key = line
      sub(/=.*/, "", key)
      rest = line
      sub(/^[A-Za-z_][A-Za-z0-9_]*=/, "", rest)
      if (match(rest, /[A-Z_][A-Z0-9_]{3,}=/)) {
        key2 = substr(rest, RSTART, RLENGTH-1)
        print NR": line for "key" appears to contain a second assignment (" key2 "=) glued on — values never printed"
      }
    }
  ' "$candidate")"

  if [ -n "$bad" ]; then
    printf 'REFUSE: %s\n' "$bad"
    return 1
  fi

  local new_count old_count
  new_count="$(_count_keys "$candidate")"
  old_count="$(_count_keys "$current")"

  # A lower count always means at least one name was removed (each NAME=
  # line is a unique key), so this is strictly implied by -- and weaker
  # than -- the named removal-guard in _main (llm#1024): that one shows
  # exactly which keys would be deleted and gates on --allow-removals; this
  # one only sees a bare number and had no override, so it refused a
  # deliberate, --allow-removals'd deletion before _main's guard ever ran
  # (llm#945). Deferring to that guard here, rather than duplicating its
  # check with a cruder, override-less one.
  if [ "$new_count" -lt "$old_count" ] && [ "$ALLOW_REMOVALS" != "1" ]; then
    echo "REFUSE: fetched ${new_count} keys, fewer than current cache's ${old_count} -- refusing to shrink the cache (re-run with --allow-removals to see exactly which keys and confirm)"
    return 1
  fi

  echo "OK: fetched ${new_count} keys (current cache has ${old_count})"
  return 0
}

# Prints the key names present in the CURRENT cache but absent from the
# CANDIDATE — i.e. exactly what installing would delete. Empty output means no
# removals. Used both by the refusal guard below and by the drift check
# (secrets_cache_drift.sh), so the two can never disagree about what counts as
# a removal.
ALLOW_REMOVALS="${ALLOW_REMOVALS:-0}"

_removed_names() {
  local current="$1" candidate="$2"
  comm -23 \
    <(_key_names "$current"   | sort -u) \
    <(_key_names "$candidate" | sort -u) 2>/dev/null
}

_names_added_removed() {
  local current="$1" candidate="$2"
  local cur_names new_names
  cur_names="$(_key_names "$current" | sort -u)"
  new_names="$(_key_names "$candidate" | sort -u)"

  local added removed
  added="$(comm -13 <(printf '%s\n' "$cur_names") <(printf '%s\n' "$new_names") 2>/dev/null)"
  removed="$(comm -23 <(printf '%s\n' "$cur_names") <(printf '%s\n' "$new_names") 2>/dev/null)"

  echo "Added:"
  if [ -n "$added" ]; then
    printf '  %s\n' $added
  else
    echo "  (none)"
  fi
  echo "Removed:"
  if [ -n "$removed" ]; then
    printf '  %s\n' $removed
  else
    echo "  (none)"
  fi
}

_install_cache() {
  # $1 = validated candidate file, $2 = destination cache path.
  # Backs up any existing cache, installs atomically, chmod 600, prepends
  # the GENERATED header, ensures a trailing newline. Prints the backup
  # path (or empty string if there was nothing to back up).
  local candidate="$1" cache_file="$2"

  local ts
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  local backup=""
  if [ -f "$cache_file" ]; then
    local bts
    bts="$(date -u '+%Y%m%dT%H%M%SZ')"
    backup="${cache_file}.bak-${bts}"
    cp -p "$cache_file" "$backup"
    chmod 600 "$backup"
  fi

  local final_tmp
  final_tmp="$(mktemp "${cache_file}.XXXXXX")"
  chmod 600 "$final_tmp"

  {
    echo "# GENERATED by secrets_cache_regen.sh from Bitwarden Secrets Manager"
    echo "# DO NOT EDIT — edit in BWS and re-run this script"
    echo "# Generated: ${ts}"
    cat "$candidate"
  } >"$final_tmp"

  # Ensure a trailing newline (defensive against a candidate whose last
  # line lacked one — this is the exact append-corruption shape we guard
  # against on the read side too).
  if [ -s "$final_tmp" ]; then
    tail -c1 "$final_tmp" | grep -q $'\n' || printf '\n' >>"$final_tmp"
  fi

  chmod 600 "$final_tmp"
  mv -f "$final_tmp" "$cache_file"
  chmod 600 "$cache_file"

  printf '%s' "$backup"
}

# ── Self-test (never calls the real bws binary) ─────────────────────────

_selftest() {
  local pass=0 fail=0
  local sentinel="sk9x2qz7mp4vlwt8"

  _t() {
    local label="$1" expected="$2" got="$3"
    if [ "$got" = "$expected" ]; then
      pass=$((pass + 1))
      printf "  PASS [%s]\n" "$label"
    else
      fail=$((fail + 1))
      printf "  FAIL [%s]: expected='%s' got='%s'\n" "$label" "$expected" "$got"
    fi
  }

  local tmpdir
  tmpdir="$(mktemp -d)"

  local current="$tmpdir/current.env"
  cat >"$current" <<EOF
# GENERATED by secrets_cache_regen.sh from Bitwarden Secrets Manager
# DO NOT EDIT — edit in BWS and re-run this script
# Generated: 2026-01-01T00:00:00Z
FAKE_A=${sentinel}a
FAKE_B=${sentinel}b
FAKE_C=${sentinel}c
EOF
  chmod 600 "$current"

  # Case: malformed line -> refused
  local malformed="$tmpdir/malformed.env"
  cat >"$malformed" <<EOF
FAKE_A=${sentinel}a
this is not a valid line
FAKE_C=${sentinel}c
FAKE_D=${sentinel}d
EOF
  local out0 rc0
  out0="$(_validate_fetch "$malformed" "$current" 2>&1)"
  rc0=$?
  case "$out0" in
  *"REFUSE"*"malformed line"*)
    pass=$((pass + 1))
    echo "  PASS [malformed line -> refused]"
    ;;
  *)
    fail=$((fail + 1))
    echo "  FAIL [malformed line -> refused]: $out0"
    ;;
  esac
  _t "malformed line exit code" "1" "$rc0"

  # Case: mock-BWS returns FEWER keys than current -> refused
  local fewer="$tmpdir/fewer.env"
  cat >"$fewer" <<EOF
FAKE_A=${sentinel}a
FAKE_B=${sentinel}b
EOF
  local out1 rc1
  out1="$(_validate_fetch "$fewer" "$current" 2>&1)"
  rc1=$?
  case "$out1" in
  *"REFUSE"*"fewer"*)
    pass=$((pass + 1))
    echo "  PASS [fewer keys -> refused]"
    ;;
  *)
    fail=$((fail + 1))
    echo "  FAIL [fewer keys -> refused]: $out1"
    ;;
  esac
  _t "fewer keys exit code" "1" "$rc1"

  # Case: mock-BWS returns FEWER keys, but ALLOW_REMOVALS=1 -> proceeds
  # (llm#945: this was the missing wiring -- the blunt count check above
  # had no override and refused before _main's named removal-guard, which
  # DOES gate on --allow-removals, ever got a chance to run).
  local out1b rc1b
  out1b="$(ALLOW_REMOVALS=1 _validate_fetch "$fewer" "$current" 2>&1)"
  rc1b=$?
  case "$out1b" in
  *"OK"*)
    pass=$((pass + 1))
    echo "  PASS [fewer keys + ALLOW_REMOVALS=1 -> proceeds]"
    ;;
  *)
    fail=$((fail + 1))
    echo "  FAIL [fewer keys + ALLOW_REMOVALS=1 -> proceeds]: $out1b"
    ;;
  esac
  _t "fewer keys + ALLOW_REMOVALS=1 exit code" "0" "$rc1b"

  # Case: mock-BWS returns a line with two assignments glued -> refused
  local glued="$tmpdir/glued.env"
  cat >"$glued" <<EOF
FAKE_A=${sentinel}a
FAKE_B=${sentinel}bFAKE_ROTATED_TOKEN=${sentinel}glued
FAKE_C=${sentinel}c
FAKE_D=${sentinel}d
EOF
  local out2 rc2
  out2="$(_validate_fetch "$glued" "$current" 2>&1)"
  rc2=$?
  case "$out2" in
  *"REFUSE"*"second assignment"*)
    pass=$((pass + 1))
    echo "  PASS [glued two-assignment line -> refused]"
    ;;
  *)
    fail=$((fail + 1))
    echo "  FAIL [glued two-assignment line -> refused]: $out2"
    ;;
  esac
  _t "glued line exit code" "1" "$rc2"
  case "$out2" in
  *"${sentinel}"*)
    fail=$((fail + 1))
    echo "  FAIL: glued-line diagnostic leaked a raw secret value"
    ;;
  *)
    pass=$((pass + 1))
    echo "  PASS [glued-line diagnostic does not leak raw value]"
    ;;
  esac

  # Case: valid larger fetch -> accepted; added/removed names reported
  local bigger="$tmpdir/bigger.env"
  cat >"$bigger" <<EOF
FAKE_A=${sentinel}a
FAKE_B=${sentinel}b-rotated
FAKE_E=${sentinel}e
EOF
  local out3 rc3
  out3="$(_validate_fetch "$bigger" "$current" 2>&1)"
  rc3=$?
  _t "valid larger fetch accepted" "0" "$rc3"
  case "$out3" in
  *"${sentinel}"*)
    fail=$((fail + 1))
    echo "  FAIL: validate-OK report leaked a raw secret value"
    ;;
  *)
    pass=$((pass + 1))
    echo "  PASS [validate-OK report has no raw value]"
    ;;
  esac

  local names_out
  names_out="$(_names_added_removed "$current" "$bigger" 2>&1)"
  case "$names_out" in
  *"FAKE_E"*)
    pass=$((pass + 1))
    echo "  PASS [added name reported: FAKE_E]"
    ;;
  *)
    fail=$((fail + 1))
    echo "  FAIL [added name]: $names_out"
    ;;
  esac
  case "$names_out" in
  *"FAKE_C"*)
    pass=$((pass + 1))
    echo "  PASS [removed name reported: FAKE_C]"
    ;;
  *)
    fail=$((fail + 1))
    echo "  FAIL [removed name]: $names_out"
    ;;
  esac
  case "$names_out" in
  *"${sentinel}"*)
    fail=$((fail + 1))
    echo "  FAIL: added/removed report leaked a raw secret value"
    ;;
  *)
    pass=$((pass + 1))
    echo "  PASS [added/removed report has no raw value]"
    ;;
  esac

  # Case: install — atomic, backed up, headers present, mode 600, and the
  # value legitimately DOES end up in the installed FILE (proving the
  # cache mechanism works even though the report never printed it).
  local install_target="$tmpdir/installed.env"
  cp "$current" "$install_target"
  chmod 600 "$install_target"
  local backup_path
  backup_path="$(_install_cache "$bigger" "$install_target")"

  if [ -n "$backup_path" ] && [ -f "$backup_path" ]; then
    pass=$((pass + 1))
    echo "  PASS [backup file created]"
  else
    fail=$((fail + 1))
    echo "  FAIL [backup file created]: got '$backup_path'"
  fi

  if grep -q "GENERATED by secrets_cache_regen.sh" "$install_target"; then
    pass=$((pass + 1))
    echo "  PASS [header present in installed cache]"
  else
    fail=$((fail + 1))
    echo "  FAIL [header present in installed cache]"
  fi

  if grep -q "${sentinel}e" "$install_target"; then
    pass=$((pass + 1))
    echo "  PASS [installed cache file legitimately contains the new value]"
  else
    fail=$((fail + 1))
    echo "  FAIL [installed cache file legitimately contains the new value]"
  fi

  local perm
  perm="$(stat -f '%Lp' "$install_target" 2>/dev/null || stat -c '%a' "$install_target" 2>/dev/null)"
  _t "installed cache mode 600" "600" "$perm"

  # Aggregate: none of the captured *reports* leak the raw sentinel.
  local combined="$out0 $out1 $out2 $out3 $names_out"
  case "$combined" in
  *"${sentinel}"*)
    fail=$((fail + 1))
    echo "  FAIL: some script report output leaked the raw sentinel value (aggregate check)"
    ;;
  *)
    pass=$((pass + 1))
    echo "  PASS [no script report output leaks raw sentinel value, aggregate check]"
    ;;
  esac

  rm -rf "$tmpdir"

  echo ""
  printf "%d/%d PASS\n" "$pass" "$((pass + fail))"
  [ "$fail" -eq 0 ] && return 0 || return 1
}

# ── Usage ─────────────────────────────────────────────────────────────────

_usage() {
  cat >&2 <<'EOF'
Usage:
  secrets_cache_regen.sh [--dry-run|--apply] [--cache-file <path>]
  secrets_cache_regen.sh --selftest

Options:
  --dry-run     Default. Fetch + validate; make no writes.
  --apply       Install the validated fetch as the new cache.
  --cache-file  Override the default ~/.config/secrets.env path.
  --selftest    Run built-in tests against fixture data only.
  --help        Show this message.

Refuses to install on: empty/failed fetch, fewer keys than the current
cache, malformed lines, or a line with two assignments glued together.
EOF
}

# ── Main ──────────────────────────────────────────────────────────────────

_main() {
  local mode="dry-run"
  local cache_file="$CACHE_FILE"

  while [ $# -gt 0 ]; do
    case "$1" in
    --apply)
      mode="apply"
      shift
      ;;
    --dry-run)
      mode="dry-run"
      shift
      ;;
    --allow-removals)
      # Opt in to deleting keys that exist in the cache but not in BWS.
      # Without this the script refuses and changes nothing (llm#1024).
      ALLOW_REMOVALS=1
      shift
      ;;
    --cache-file)
      cache_file="$2"
      shift 2
      ;;
    --selftest)
      _selftest
      exit $?
      ;;
    --help | -h)
      _usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      _usage
      exit 2
      ;;
    esac
  done

  local candidate
  candidate="$(mktemp)"
  chmod 600 "$candidate"

  if ! _bws_fetch_env >"$candidate" 2>/dev/null; then
    echo "ERROR: bws secret list -o env failed" >&2
    rm -f "$candidate"
    exit 1
  fi

  local verdict vrc
  verdict="$(_validate_fetch "$candidate" "$cache_file")"
  vrc=$?
  echo "$verdict"

  if [ "$vrc" -ne 0 ]; then
    rm -f "$candidate"
    exit 1
  fi

  local old_count new_count
  old_count="$(_count_keys "$cache_file")"
  new_count="$(_count_keys "$candidate")"
  echo "Keys before: $old_count"
  echo "Keys after:  $new_count"
  # A stable count is NOT evidence of a stable key set: 15 -> 15 is what an
  # add-plus-a-delete looks like, and that is exactly how SIGNAL_ACCOUNT went
  # unnoticed (llm#1024). Report the churn, not just the total.
  {
    _n_added="$(comm -13 <(_key_names "$cache_file" | sort -u) <(_key_names "$candidate" | sort -u) 2>/dev/null | grep -c . || true)"
    _n_removed="$(_removed_names "$cache_file" "$candidate" | grep -c . || true)"
    echo "Churn:       +${_n_added:-0} / -${_n_removed:-0}"
  }
  _names_added_removed "$cache_file" "$candidate"

  # ── Removal guard (llm#1024) ────────────────────────────────────────────
  # Deleting a key is the only irreversible thing this script does, and until
  # now it happened at the same volume as everything else: a "Removed:" line
  # between two lines of progress output, exit 0.
  #
  # On 2026-08-25 a regen run to add CACHIX_AUTH_TOKEN also dropped
  # SIGNAL_ACCOUNT, which lived only in the cache and had never been migrated
  # to BWS. Both Signal entry points fail closed without it (llm#946), so
  # capture stopped — the same capability repaired that morning under llm#1001.
  # The summary said "Keys before: 15 / Keys after: 15", which reads like a
  # no-op precisely BECAUSE one key was added as another was removed. Two
  # people read that output and neither noticed.
  #
  # A key in the cache but not in BWS is not noise: it is a value that exists
  # in exactly one place, and this script is the thing that deletes it. Refuse
  # by default; make the operator say so.
  local removed_list
  removed_list="$(_removed_names "$cache_file" "$candidate")"

  if [ -n "$removed_list" ] && [ "$ALLOW_REMOVALS" != "1" ]; then
    local removed_count
    removed_count="$(printf '%s\n' "$removed_list" | grep -c .)"
    echo ""
    echo "REFUSED: ${removed_count} key(s) in the cache are absent from Bitwarden and would be DELETED:"
    printf '           %s\n' $removed_list
    echo ""
    echo "         These exist in ~/.config/secrets.env and nowhere else. Installing"
    echo "         this cache would destroy them. Nothing has been changed."
    echo ""
    echo "         To keep a key, put it in Bitwarden first:"
    printf '             ~/.claude/scripts/bws_set_secret.sh %s\n' $removed_list
    echo ""
    echo "         To delete it deliberately, re-run with --allow-removals."
    echo ""
    echo "         (llm#1024 — this guard exists because an unrelated regen"
    echo "          silently dropped SIGNAL_ACCOUNT and disabled Signal capture.)"
    rm -f "$candidate"
    exit 1
  fi

  if [ -n "$removed_list" ]; then
    echo "PROCEEDING WITH REMOVALS (--allow-removals given) — these keys will be deleted:"
    printf '    %s\n' $removed_list
  fi

  if [ "$mode" != "apply" ]; then
    echo "[dry-run] Would install $new_count keys to $cache_file. Re-run with --apply."
    rm -f "$candidate"
    exit 0
  fi

  local backup
  backup="$(_install_cache "$candidate" "$cache_file")"
  [ -n "$backup" ] && echo "Backed up previous cache to: $backup"
  echo "Installed new cache: $cache_file"
  rm -f "$candidate" 2>/dev/null || true
}

_main "$@"
