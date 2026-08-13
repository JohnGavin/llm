#!/usr/bin/env bash
# secrets_to_bws.sh — one-time migration: push everything in secrets.env
# into Bitwarden Secrets Manager (BWS) that is not already there.
#
# BWS is the system of record (see .claude/rules/secrets-single-source.md).
# ~/.config/secrets.env is a derived, regenerable cache — see
# secrets_cache_regen.sh for the reverse direction (BWS -> cache).
#
# HARD SAFETY REQUIREMENT: this script NEVER overwrites an existing BWS
# secret. A name already present in BWS is always reported as a conflict
# (with a truncated sha256 comparison of each side) and left untouched,
# regardless of whether the local secrets.env value agrees with it. This
# is not a preference — it structurally prevents a corrupted local value
# from ever clobbering a correct BWS value. See the rule doc for the
# GMAIL_APP_PASSWORD incident that motivates this.
#
# Usage:
#   secrets_to_bws.sh [--dry-run|--apply] [--secrets-env <path>]
#   secrets_to_bws.sh --selftest
#
# --dry-run      Default. Still queries BWS (read-only) to compute the
#                report; makes no writes.
# --apply        Executes `bws secret create` for names missing from BWS.
#                Requires BWS_ACCESS_TOKEN to already be set in the
#                environment by the caller — this script never fetches it
#                itself (no Keychain access, no vault calls beyond the
#                documented read/create operations).
# --secrets-env  Override the default ~/.config/secrets.env path.
# --selftest     Run built-in tests against fixture data and a mocked BWS
#                response. Never invokes the real `bws` binary.
#
# ASSUMPTION (unverified against a live `bws` invocation — this script
# intentionally never calls the real binary during development/testing):
# `bws secret create <key> <value> <project-id>` positional argument
# order. Confirm with `bws secret create --help` before the first real
# --apply run and adjust `_bws_create` below if the order differs.
#
# Never prints a raw secret value. Only names, truncated sha256 hashes
# (12 chars), and lengths appear in output.
#
# Tracked in JohnGavin/llm (secrets single-source-of-truth migration).

set -uo pipefail

export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

BWS_BIN="${BWS_BIN:-bws}"
SECRETS_ENV="${SECRETS_ENV:-$HOME/.config/secrets.env}"

# Names present in secrets.env that are configuration flags, not
# credentials. They are intentionally never migrated to BWS. Audit this
# list whenever a new `export NAME=VALUE` line is added to secrets.env
# that is not itself a secret.
NON_SECRET_NAMES="GEMINI_CLI_TRUST_WORKSPACE CODEX_SANDBOX"

# ── Pure / directly-testable functions ──────────────────────────────────

_is_non_secret() {
  local name="$1"
  local n
  for n in $NON_SECRET_NAMES; do
    [ "$n" = "$name" ] && return 0
  done
  return 1
}

_sha12() {
  # Truncated sha256 of a value — lets us compare two secrets without ever
  # printing either one.
  printf '%s' "$1" | shasum -a 256 2>/dev/null | cut -c1-12
}

_export_names() {
  # Names only (no values) of every `export NAME=VALUE` line in $1.
  local file="$1"
  [ -r "$file" ] || return 0
  grep -E '^[[:space:]]*export[[:space:]]+[A-Za-z_][A-Za-z0-9_]*=' "$file" 2>/dev/null |
    sed -E 's/^[[:space:]]*export[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)=.*/\1/'
}

_read_env_pairs() {
  # Sources $1 in an isolated subshell — the same semantics a real login
  # shell uses when loading secrets.env — and emits "NAME\tVALUE" for each
  # export line's name, reading the value back via indirect expansion.
  # Sourcing (rather than hand-parsing quotes) is deliberate: it is the
  # only way to faithfully reproduce whatever bash's own quoting rules
  # produced, including malformed cases like quotes-and-spaces baked into
  # a value by a bad prior migration.
  local file="$1"
  [ -r "$file" ] || return 0
  local names
  names="$(_export_names "$file")"
  [ -n "$names" ] || return 0
  (
    set -a
    # shellcheck disable=SC1090
    . "$file" >/dev/null 2>&1
    set +a
    local n
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      printf '%s\t%s\n' "$n" "${!n-}"
    done <<EOF
$names
EOF
  )
}

_bws_list_json() {
  # Live call — only reached outside --selftest.
  "$BWS_BIN" secret list -o json
}

_bws_get_json() {
  # Live call — only reached outside --selftest.
  local id="$1"
  "$BWS_BIN" secret get "$id" -o json
}

_bws_create() {
  # Live call — only reached outside --selftest, and only in --apply mode.
  local project_id="$1" name="$2" value="$3"
  "$BWS_BIN" secret create "$name" "$value" "$project_id" >/dev/null
}

_bws_existing_map() {
  # Emits "NAME\tID\tVALUE" for every secret in the given `bws secret list
  # -o json` output.
  local json="$1"
  printf '%s' "$json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = []
for item in data:
    key = item.get("key", "")
    val = item.get("value", "")
    sid = item.get("id", "")
    print(f"{key}\t{sid}\t{val}")
'
}

_bws_project_id_from_existing() {
  # `bws project list` returns empty for this machine-account token, so we
  # derive a project id from an existing secret instead. Tries the list
  # json's own projectId field first; if that field is absent, falls back
  # to `bws secret get <id> -o json` on the first listed secret (per the
  # documented fact that `get` includes projectId). Prints nothing and
  # returns 1 if neither source yields a value — callers must treat that
  # as a hard error, never a guess.
  local list_json="$1"
  local pid
  pid="$(printf '%s' "$list_json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = []
for item in data:
    p = item.get("projectId") or item.get("project_id")
    if p:
        print(p)
        break
')"
  if [ -n "$pid" ]; then
    printf '%s' "$pid"
    return 0
  fi

  local first_id
  first_id="$(printf '%s' "$list_json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = []
print(data[0]["id"] if data else "")
')"
  [ -n "$first_id" ] || return 1

  local get_json
  get_json="$(_bws_get_json "$first_id")" || return 1
  pid="$(printf '%s' "$get_json" | python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    data = json.loads(raw)
except Exception:
    sys.exit(0)
if isinstance(data, list):
    data = data[0] if data else {}
print(data.get("projectId") or data.get("project_id") or "")
')"
  [ -n "$pid" ] || return 1
  printf '%s' "$pid"
  return 0
}

_run_migration_core() {
  # Pure-ish core: takes the secrets.env path, mode, and an already-fetched
  # `bws secret list -o json` string. Selftest calls this directly with
  # fixture json so it never has to touch the real bws binary.
  local secrets_env="$1" mode="$2" existing_json="$3"

  local pairs
  pairs="$(_read_env_pairs "$secrets_env")"
  if [ -z "$pairs" ]; then
    echo "ERROR: no export NAME=VALUE lines found in $secrets_env" >&2
    return 1
  fi

  local existing_map
  existing_map="$(_bws_existing_map "$existing_json")"

  local project_id=""
  project_id="$(_bws_project_id_from_existing "$existing_json")" || project_id=""

  local created=0 skipped_non_secret=0 conflicts=0 errors=0
  local name value

  while IFS=$'\t' read -r name value; do
    [ -n "$name" ] || continue

    if _is_non_secret "$name"; then
      echo "SKIP  (non-secret): $name"
      skipped_non_secret=$((skipped_non_secret + 1))
      continue
    fi

    local existing_line
    existing_line="$(printf '%s\n' "$existing_map" | awk -F'\t' -v n="$name" '$1==n{print; exit}')"

    if [ -z "$existing_line" ]; then
      local vlen=${#value}
      if [ -z "$project_id" ]; then
        echo "ERROR (no BWS project id available — cannot create): $name (len=$vlen)" >&2
        errors=$((errors + 1))
        continue
      fi
      if [ "$mode" = "apply" ]; then
        if _bws_create "$project_id" "$name" "$value"; then
          echo "CREATE: $name (len=$vlen)"
          created=$((created + 1))
        else
          echo "ERROR (create failed): $name (len=$vlen)" >&2
          errors=$((errors + 1))
        fi
      else
        echo "WOULD CREATE: $name (len=$vlen)"
        created=$((created + 1))
      fi
      continue
    fi

    # Already in BWS: NEVER overwrite. Report as a conflict either way, so
    # the operator explicitly reviews migration status name by name; the
    # hash comparison tells them whether it is benign (values agree) or
    # dangerous (values differ — the exact GMAIL_APP_PASSWORD shape).
    local existing_value local_hash bws_hash
    existing_value="$(printf '%s' "$existing_line" | awk -F'\t' '{print $3}')"
    local_hash="$(_sha12 "$value")"
    bws_hash="$(_sha12 "$existing_value")"

    if [ "$local_hash" = "$bws_hash" ]; then
      echo "CONFLICT ($name): already in BWS, values AGREE — no action taken. local_sha12=$local_hash bws_sha12=$bws_hash"
    else
      echo "CONFLICT ($name): already in BWS, values DIFFER — NOT overwritten. local_sha12=$local_hash bws_sha12=$bws_hash local_len=${#value} bws_len=${#existing_value}"
    fi
    conflicts=$((conflicts + 1))
  done <<EOF
$pairs
EOF

  echo ""
  echo "Summary: created=$created skipped-non-secret=$skipped_non_secret conflict=$conflicts error=$errors"

  if [ "$conflicts" -gt 0 ] || [ "$errors" -gt 0 ]; then
    return 1
  fi
  return 0
}

_run_migration() {
  local secrets_env="$1" mode="$2"

  echo "Fetching current BWS secret list..." >&2
  local existing_json
  existing_json="$(_bws_list_json)" || {
    echo "ERROR: bws secret list failed" >&2
    return 1
  }

  _run_migration_core "$secrets_env" "$mode" "$existing_json"
}

# ── Self-test (never calls the real bws binary) ─────────────────────────

_selftest() {
  local pass=0 fail=0
  local sentinel="zq93selftestonly7k"

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
  local fixture_env="$tmpdir/secrets.env.fixture"
  cat >"$fixture_env" <<EOF
export FAKE_NEW_SECRET=${sentinel}new
export FAKE_CONFLICT_SECRET="  'quoted and spaced' ${sentinel}conflictlocal  "
export GEMINI_CLI_TRUST_WORKSPACE=true
export CODEX_SANDBOX=danger
EOF

  # BWS already has FAKE_CONFLICT_SECRET with a DIFFERENT value, and that
  # record supplies the project id used for the FAKE_NEW_SECRET create.
  local mock_list_conflict
  mock_list_conflict=$(python3 -c "
import json
print(json.dumps([
  {'id':'11111111-1111-1111-1111-111111111111','key':'FAKE_CONFLICT_SECRET','value':'${sentinel}conflictbws','projectId':'proj-aaaa'}
]))
")

  local out
  out="$(_run_migration_core "$fixture_env" "dry-run" "$mock_list_conflict" 2>&1)"
  local rc=$?

  case "$out" in
  *"${sentinel}"*)
    fail=$((fail + 1))
    echo "  FAIL [sentinel not printed]: output leaked a raw secret value"
    ;;
  *)
    pass=$((pass + 1))
    echo "  PASS [sentinel not printed]"
    ;;
  esac

  case "$out" in
  *"WOULD CREATE: FAKE_NEW_SECRET"*)
    pass=$((pass + 1))
    echo "  PASS [key absent from BWS -> would create]"
    ;;
  *)
    fail=$((fail + 1))
    echo "  FAIL [key absent from BWS -> would create]: $out"
    ;;
  esac

  case "$out" in
  *"CONFLICT (FAKE_CONFLICT_SECRET)"*"DIFFER"*)
    pass=$((pass + 1))
    echo "  PASS [differing existing value -> conflict, not overwritten]"
    ;;
  *)
    fail=$((fail + 1))
    echo "  FAIL [differing existing value -> conflict]: $out"
    ;;
  esac

  case "$out" in
  *"CREATE: FAKE_CONFLICT_SECRET"*)
    fail=$((fail + 1))
    echo "  FAIL: a conflicting existing secret was (would-be) created/overwritten — must never happen"
    ;;
  *)
    pass=$((pass + 1))
    echo "  PASS [conflicting existing secret never (would-be) overwritten]"
    ;;
  esac

  case "$out" in
  *"SKIP  (non-secret): GEMINI_CLI_TRUST_WORKSPACE"*)
    pass=$((pass + 1))
    echo "  PASS [non-secret skipped: GEMINI_CLI_TRUST_WORKSPACE]"
    ;;
  *)
    fail=$((fail + 1))
    echo "  FAIL [non-secret skip]: $out"
    ;;
  esac

  case "$out" in
  *"SKIP  (non-secret): CODEX_SANDBOX"*)
    pass=$((pass + 1))
    echo "  PASS [non-secret skipped: CODEX_SANDBOX]"
    ;;
  *)
    fail=$((fail + 1))
    echo "  FAIL [non-secret skip 2]: $out"
    ;;
  esac

  _t "exit non-zero on conflict" "1" "$rc"

  # Matching-value case: BWS already holds FAKE_NEW_SECRET with the SAME
  # value — still a conflict (never a create), agreement noted.
  local mock_list_match
  mock_list_match=$(python3 -c "
import json
print(json.dumps([
  {'id':'22222222-2222-2222-2222-222222222222','key':'FAKE_NEW_SECRET','value':'${sentinel}new','projectId':'proj-aaaa'}
]))
")
  local out2
  out2="$(_run_migration_core "$fixture_env" "dry-run" "$mock_list_match" 2>&1)"

  case "$out2" in
  *"CONFLICT (FAKE_NEW_SECRET)"*"AGREE"*)
    pass=$((pass + 1))
    echo "  PASS [matching existing value -> conflict reported as agreeing]"
    ;;
  *)
    fail=$((fail + 1))
    echo "  FAIL [matching existing value case]: $out2"
    ;;
  esac
  case "$out2" in
  *"CREATE: FAKE_NEW_SECRET"*)
    fail=$((fail + 1))
    echo "  FAIL: matching-value existing secret was (would-be) created — must never happen"
    ;;
  *)
    pass=$((pass + 1))
    echo "  PASS [matching-value existing secret never (would-be) created]"
    ;;
  esac

  # No usable project id (empty BWS) -> clear error, not a guess.
  local out3
  out3="$(_run_migration_core "$fixture_env" "dry-run" "[]" 2>&1)"
  case "$out3" in
  *"ERROR"*"no BWS project id available"*)
    pass=$((pass + 1))
    echo "  PASS [no project id derivable -> clear error, not a guess]"
    ;;
  *)
    fail=$((fail + 1))
    echo "  FAIL [no project id derivable case]: $out3"
    ;;
  esac

  # Aggregate: no captured output anywhere leaks the raw sentinel value.
  local combined="$out $out2 $out3"
  case "$combined" in
  *"${sentinel}"*)
    fail=$((fail + 1))
    echo "  FAIL: some script output leaked the raw sentinel value (aggregate check)"
    ;;
  *)
    pass=$((pass + 1))
    echo "  PASS [no script output leaks raw sentinel value, aggregate check]"
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
  secrets_to_bws.sh [--dry-run|--apply] [--secrets-env <path>]
  secrets_to_bws.sh --selftest

Options:
  --dry-run      Default. Query BWS and print the report; make no writes.
  --apply        Create BWS secrets that are missing. Requires
                 BWS_ACCESS_TOKEN already set in the environment.
  --secrets-env  Override the default ~/.config/secrets.env path.
  --selftest     Run built-in tests against fixture/mocked data only.
  --help         Show this message.

Never overwrites a secret that already exists in BWS. Never prints a raw
secret value.
EOF
}

# ── Main ──────────────────────────────────────────────────────────────────

_main() {
  local mode="dry-run"
  local secrets_env="$SECRETS_ENV"

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
    --secrets-env)
      secrets_env="$2"
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

  if [ ! -r "$secrets_env" ]; then
    echo "ERROR: cannot read $secrets_env" >&2
    exit 1
  fi

  if [ "$mode" = "apply" ] && [ -z "${BWS_ACCESS_TOKEN:-}" ]; then
    echo "ERROR: --apply requires BWS_ACCESS_TOKEN in the environment (this script will not fetch it itself)." >&2
    exit 1
  fi

  _run_migration "$secrets_env" "$mode"
}

_main "$@"
