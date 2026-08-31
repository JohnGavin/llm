#!/usr/bin/env bash
#
# agentsview_quality_baseline.sh
#
# Implements the substantive-session filtering recipe from
# .claude/rules/agentsview-quality-baseline.md (JohnGavin/llm#1115) end to
# end, for a given project directory name or AgentsView bucket name. Turns
# the manual CLI recipe from that survey into a repeatable command.
#
# Usage:
#   agentsview_quality_baseline.sh <project-dirname-or-bucket> [--json]
#   agentsview_quality_baseline.sh --selftest
#
# What it does:
#   1. Resolves EVERY AgentsView bucket whose cwd matches <dirname-or-bucket>
#      (the rule's caveat 3 multi-bucket case) -- never silently picks one.
#   2. For each bucket, computes the raw total and the substantive-session
#      stats (message_count>=30 AND is_automated==false, verified client-side
#      from the JSON rather than trusting the CLI flags alone).
#   3. Aggregates the substantive count across all resolved buckets and
#      assigns a trust tier (baseline-ready / building / too-thin).
#
# Exit codes (per checks-must-distinguish-unknown -- a real zero must never
# look like "could not determine"):
#   0 = ran successfully; a trust tier was determined. This INCLUDES tier
#       "too-thin" with substantive_n=0 -- that is a real, verified zero,
#       not "could not run".
#   1 = reserved for future use. Never currently emitted.
#   2 = INDETERMINATE -- could not run the recipe at all: agentsview/sqlite3/
#       jq missing from PATH, the sessions.db unreadable, no bucket matched
#       the given name, or a query errored/returned unparseable output. NEVER
#       rendered as tier "too-thin" -- always a distinct, clearly labelled
#       state (see _emit_indeterminate()).
#
# NEVER combines --min-messages with --include-children (rule caveat 4:
# verified unreliable together) -- this script does not use
# --include-children anywhere.
#
# Dependencies: agentsview CLI, sqlite3, jq. Override the DB path with
# AGENTSVIEW_DB (default: ~/.agentsview/sessions.db) -- used by --selftest
# to point at a synthetic fixture DB without touching the real one.

set -uo pipefail

# ── DB path (dynamic -- re-read per call so tests can override it) ─────────
_db_path() {
  printf '%s' "${AGENTSVIEW_DB:-$HOME/.agentsview/sessions.db}"
}

# ── Dependency check ─────────────────────────────────────────────────────
# Returns 0 with nothing printed if all deps are present; returns 2 and
# prints a one-line human-readable reason on stdout otherwise. Caller
# captures the reason via command substitution.
_check_deps() {
  local missing=()
  command -v agentsview >/dev/null 2>&1 || missing+=("agentsview")
  command -v sqlite3 >/dev/null 2>&1 || missing+=("sqlite3")
  command -v jq >/dev/null 2>&1 || missing+=("jq")
  if [ "${#missing[@]}" -gt 0 ]; then
    local joined
    joined=$(IFS=,; echo "${missing[*]}")
    printf 'missing on PATH: %s\n' "$joined"
    return 2
  fi
  local db
  db=$(_db_path)
  if [ ! -r "$db" ]; then
    printf 'AgentsView sessions DB not readable: %s\n' "$db"
    return 2
  fi
  return 0
}

# ── Multi-bucket resolution (rule caveat 3) ──────────────────────────────
# Prints "project|count|max_cwd" lines, one per matching bucket. Empty
# output (with exit 0) means "no bucket matched" -- the caller must treat
# that as INDETERMINATE, not as a real zero, since we cannot tell whether
# the project genuinely has no AgentsView data or the name is simply wrong.
_resolve_buckets() {
  local dirname="$1" db
  db=$(_db_path)
  # Escape single quotes defensively before splicing into the SQL literal.
  local escaped="${dirname//\'/\'\'}"
  sqlite3 -readonly -noheader -list -separator '|' "$db" \
    "SELECT project, count(*), max(cwd) FROM sessions WHERE cwd LIKE '%${escaped}%' GROUP BY project;"
}

# ── Safe JSON call: runs "$@", returns the stdout only if it is valid JSON ─
_safe_json_call() {
  local out
  out=$("$@" 2>/dev/null)
  if [ -z "$out" ]; then
    return 1
  fi
  if ! printf '%s' "$out" | jq empty >/dev/null 2>&1; then
    return 1
  fi
  printf '%s' "$out"
}

# ── Raw total for one bucket (rule's exact recipe, first query) ─────────
_raw_total() {
  local bucket="$1" json
  json=$(_safe_json_call agentsview session list --project "$bucket" --limit 500 \
    --include-automated --include-one-shot --format json) || return 1
  printf '%s' "$json" | jq -r '.total // 0'
}

# ── Substantive-session JSON array for one bucket ────────────────────────
# Uses the rule's exact recipe query (--min-messages 30 --limit 500
# --include-one-shot, --include-children never added), then re-verifies
# BOTH conditions of the substantive definition client-side against the
# JSON rather than trusting the CLI flags alone did the AND correctly.
_substantive_json() {
  local bucket="$1" json
  json=$(_safe_json_call agentsview session list --project "$bucket" --min-messages 30 --limit 500 \
    --include-one-shot --format json) || return 1
  printf '%s' "$json" | jq -c '[ (.sessions // [])[]
    | select((.is_automated // false) == false)
    | select((.message_count // 0) >= 30) ]'
}

# ── Stats over a combined substantive-session JSON array ────────────────
_compute_stats() {
  jq -c '{
    n: length,
    avg_health: (if length > 0 then ([.[].health_score] | add / length) else 0 end),
    grades: (if length > 0 then (group_by(.health_grade) | map({(.[0].health_grade): length}) | add) else {} end)
  }'
}

# ── Trust tier assignment ────────────────────────────────────────────────
_assign_tier() {
  local n="$1"
  if [ "$n" -ge 10 ]; then
    echo "baseline-ready"
  elif [ "$n" -ge 3 ]; then
    echo "building"
  else
    echo "too-thin"
  fi
}

# ── INDETERMINATE emitter (distinct from tier too-thin) ──────────────────
_emit_indeterminate() {
  local reason="$1" json_flag="$2"
  if [ "$json_flag" = "1" ]; then
    jq -n --arg reason "$reason" '{indeterminate: true, tier: null, reason: $reason}'
  else
    echo "INDETERMINATE: could not compute the AgentsView quality baseline." >&2
    echo "  reason: $reason" >&2
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────
_main() {
  local query="" json_flag=0
  for arg in "$@"; do
    case "$arg" in
      --json) json_flag=1 ;;
      -*) : ;; # ignore unknown flags rather than erroring on them
      *) query="$arg" ;;
    esac
  done

  if [ -z "$query" ]; then
    echo "Usage: $(basename "$0") <project-dirname-or-bucket> [--json]" >&2
    echo "       $(basename "$0") --selftest" >&2
    return 2
  fi

  local dep_err
  if ! dep_err=$(_check_deps); then
    _emit_indeterminate "$dep_err" "$json_flag"
    return 2
  fi

  local bucket_rows
  if ! bucket_rows=$(_resolve_buckets "$query"); then
    _emit_indeterminate "sqlite3 bucket-resolution query failed for '$query'" "$json_flag"
    return 2
  fi
  if [ -z "$bucket_rows" ]; then
    _emit_indeterminate "no AgentsView bucket found matching '$query' -- cannot tell whether this project has zero AgentsView data or the name is wrong" "$json_flag"
    return 2
  fi

  local raw_sum=0
  local combined_tmp
  combined_tmp=$(mktemp)
  echo "[]" > "$combined_tmp"
  local bucket_summaries="[]"

  while IFS='|' read -r bproj bcount bcwd; do
    [ -z "$bproj" ] && continue
    local raw substantive b_n
    if ! raw=$(_raw_total "$bproj"); then
      _emit_indeterminate "agentsview raw-total query failed for bucket '$bproj'" "$json_flag"
      rm -f "$combined_tmp"
      return 2
    fi
    if ! substantive=$(_substantive_json "$bproj"); then
      _emit_indeterminate "agentsview substantive-session query failed for bucket '$bproj'" "$json_flag"
      rm -f "$combined_tmp"
      return 2
    fi
    raw_sum=$((raw_sum + raw))
    jq -c --argjson new "$substantive" '. + $new' "$combined_tmp" > "${combined_tmp}.new" && mv "${combined_tmp}.new" "$combined_tmp"
    b_n=$(printf '%s' "$substantive" | jq 'length')
    bucket_summaries=$(printf '%s' "$bucket_summaries" | jq \
      --arg b "$bproj" --argjson raw "$raw" --argjson n "$b_n" --arg cwd "$bcwd" \
      '. + [{bucket:$b, raw_total:$raw, substantive_n:$n, cwd_sample:$cwd}]')
  done <<< "$bucket_rows"

  local combined stats agg_n tier bucket_count
  combined=$(cat "$combined_tmp")
  rm -f "$combined_tmp"
  stats=$(printf '%s' "$combined" | _compute_stats)
  agg_n=$(printf '%s' "$stats" | jq -r '.n')
  tier=$(_assign_tier "$agg_n")
  bucket_count=$(printf '%s' "$bucket_summaries" | jq 'length')

  if [ "$json_flag" = "1" ]; then
    jq -n --arg query "$query" --argjson buckets "$bucket_summaries" \
      --argjson raw_total "$raw_sum" --argjson stats "$stats" --arg tier "$tier" \
      '{query: $query, indeterminate: false, buckets: $buckets,
        aggregate: ({raw_total: $raw_total} + $stats), tier: $tier}'
  else
    echo "AgentsView Quality Baseline -- $query"
    echo ""
    echo "Buckets resolved: $bucket_count"
    printf '%s' "$bucket_summaries" | jq -r \
      '.[] | "  \(.bucket)  (raw_total=\(.raw_total), substantive_n=\(.substantive_n), cwd~\(.cwd_sample))"'
    echo ""
    echo "Raw total (all buckets, --include-automated --include-one-shot): $raw_sum"
    echo "Substantive sessions (message_count>=30 AND is_automated==false), all buckets combined: $agg_n"
    printf '%s' "$stats" | jq -r '"  avg_health: \(.avg_health)\n  grades: \(.grades)"'
    echo ""
    echo "Trust tier: $tier"
    case "$tier" in
      baseline-ready) echo "  (>=10 substantive sessions -- average score and grade mix mean something)" ;;
      building)       echo "  (3-9 substantive sessions -- a trend is forming; individual sessions still dominate)" ;;
      too-thin)       echo "  (0-2 substantive sessions -- do not read the score as a quality signal yet)" ;;
    esac
  fi
  return 0
}

# ── Self-test (no live agentsview/sqlite3 dependency) ────────────────────
_selftest() {
  local pass=0 fail=0

  _t() {
    local label="$1" expected="$2" got="$3"
    if [ "$got" = "$expected" ]; then
      pass=$((pass + 1))
      echo "  PASS [$label]"
    else
      fail=$((fail + 1))
      echo "  FAIL [$label]: expected='$expected' got='$got'"
    fi
  }

  # ── Tier boundary tests (pure function, no mocking needed) ─────────────
  _t "tier: n=0 -> too-thin"        "too-thin"       "$(_assign_tier 0)"
  _t "tier: n=2 -> too-thin"        "too-thin"       "$(_assign_tier 2)"
  _t "tier: n=3 -> building"        "building"       "$(_assign_tier 3)"
  _t "tier: n=9 -> building"        "building"       "$(_assign_tier 9)"
  _t "tier: n=10 -> baseline-ready" "baseline-ready" "$(_assign_tier 10)"
  _t "tier: n=52 -> baseline-ready" "baseline-ready" "$(_assign_tier 52)"

  local mocktmp
  mocktmp=$(mktemp -d)

  # ── INDETERMINATE: no agentsview/sqlite3/jq on PATH ─────────────────────
  mkdir -p "$mocktmp/emptybin"
  local err rc
  err=$(PATH="$mocktmp/emptybin" _check_deps 2>&1)
  rc=$?
  _t "check_deps: missing binaries -> exit 2" "2" "$rc"
  _t "check_deps: reason names agentsview" "1" "$(printf '%s' "$err" | grep -q "agentsview" && echo 1 || echo 0)"

  # ── INDETERMINATE: binaries present but DB unreadable ───────────────────
  mkdir -p "$mocktmp/goodbin"
  cat > "$mocktmp/goodbin/agentsview" <<'MOCKEOF'
#!/usr/bin/env bash
has_automated=0
has_minmsg=0
for a in "$@"; do
  [ "$a" = "--include-automated" ] && has_automated=1
  [ "$a" = "--min-messages" ] && has_minmsg=1
done
if [ "$has_automated" = "1" ]; then
  echo '{"total": 100, "sessions": []}'
elif [ "$has_minmsg" = "1" ]; then
  cat <<'JSON'
{"total": 4, "sessions": [
  {"message_count": 40, "is_automated": false, "health_score": 90,  "health_grade": "A"},
  {"message_count": 35, "is_automated": true,  "health_score": 100, "health_grade": "A"},
  {"message_count": 20, "is_automated": false, "health_score": 100, "health_grade": "A"},
  {"message_count": 60, "is_automated": false, "health_score": 70,  "health_grade": "C"}
]}
JSON
else
  echo '{}'
fi
MOCKEOF
  chmod +x "$mocktmp/goodbin/agentsview"
  cat > "$mocktmp/goodbin/sqlite3" <<'MOCKEOF'
#!/usr/bin/env bash
echo "myproj|42|/Users/x/myproj"
MOCKEOF
  chmod +x "$mocktmp/goodbin/sqlite3"
  local realjq
  realjq=$(command -v jq)
  cp "$realjq" "$mocktmp/goodbin/jq"
  chmod +x "$mocktmp/goodbin/jq"

  local rc2
  AGENTSVIEW_DB="$mocktmp/nonexistent.db" PATH="$mocktmp/goodbin:$PATH" _check_deps >/dev/null 2>&1
  rc2=$?
  _t "check_deps: missing DB -> exit 2" "2" "$rc2"

  touch "$mocktmp/fake.db"

  # ── Single-bucket resolution ─────────────────────────────────────────────
  local rows
  rows=$(PATH="$mocktmp/goodbin:$PATH" AGENTSVIEW_DB="$mocktmp/fake.db" _resolve_buckets "myproj")
  _t "resolve_buckets: single-bucket row count" "1" "$(printf '%s\n' "$rows" | grep -c .)"
  _t "resolve_buckets: bucket name parsed" "myproj" "$(printf '%s\n' "$rows" | head -1 | cut -d'|' -f1)"

  # ── Multi-bucket resolution (the split-project case, rule caveat 3) ─────
  cat > "$mocktmp/goodbin/sqlite3" <<'MOCKEOF'
#!/usr/bin/env bash
echo "myproj|20|/Users/x/myproj"
echo "myproj-old|15|/Users/x/myproj-old"
MOCKEOF
  chmod +x "$mocktmp/goodbin/sqlite3"
  rows=$(PATH="$mocktmp/goodbin:$PATH" AGENTSVIEW_DB="$mocktmp/fake.db" _resolve_buckets "myproj")
  _t "resolve_buckets: multi-bucket row count" "2" "$(printf '%s\n' "$rows" | grep -c .)"
  _t "resolve_buckets: second bucket name parsed" "myproj-old" "$(printf '%s\n' "$rows" | sed -n '2p' | cut -d'|' -f1)"

  # ── No bucket matched -> caller treats as INDETERMINATE ──────────────────
  cat > "$mocktmp/goodbin/sqlite3" <<'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF
  chmod +x "$mocktmp/goodbin/sqlite3"
  rows=$(PATH="$mocktmp/goodbin:$PATH" AGENTSVIEW_DB="$mocktmp/fake.db" _resolve_buckets "nosuchproject")
  _t "resolve_buckets: no match -> empty output" "" "$rows"

  # restore multi-bucket sqlite3 mock for the raw_total/substantive tests below
  cat > "$mocktmp/goodbin/sqlite3" <<'MOCKEOF'
#!/usr/bin/env bash
echo "myproj|42|/Users/x/myproj"
MOCKEOF
  chmod +x "$mocktmp/goodbin/sqlite3"

  # ── raw_total / substantive_json parsing against fixture agentsview ─────
  local raw
  raw=$(PATH="$mocktmp/goodbin:$PATH" _raw_total "myproj")
  _t "raw_total: parses .total from --include-automated call" "100" "$raw"

  local subst subst_n
  subst=$(PATH="$mocktmp/goodbin:$PATH" _substantive_json "myproj")
  subst_n=$(printf '%s' "$subst" | jq 'length')
  # Fixture has 4 sessions: (40,false)=passes, (35,true)=fails automated,
  # (20,false)=fails message-count floor, (60,false)=passes -> n=2.
  _t "substantive_json: filters both conditions (n=2 of 4)" "2" "$subst_n"

  # ── End-to-end via _main(), fully mocked, human output ──────────────────
  local e2e_out e2e_rc
  e2e_out=$(PATH="$mocktmp/goodbin:$PATH" AGENTSVIEW_DB="$mocktmp/fake.db" _main "myproj")
  e2e_rc=$?
  _t "main: end-to-end exit 0" "0" "$e2e_rc"
  _t "main: end-to-end reports substantive n=2" "1" "$(printf '%s' "$e2e_out" | grep -q "combined: 2" && echo 1 || echo 0)"
  _t "main: end-to-end tier is too-thin (n=2)" "1" "$(printf '%s' "$e2e_out" | grep -q "Trust tier: too-thin" && echo 1 || echo 0)"

  # ── End-to-end via _main(), JSON output ──────────────────────────────────
  local e2e_json
  e2e_json=$(PATH="$mocktmp/goodbin:$PATH" AGENTSVIEW_DB="$mocktmp/fake.db" _main "myproj" "--json")
  _t "main --json: valid JSON" "1" "$(printf '%s' "$e2e_json" | jq empty >/dev/null 2>&1 && echo 1 || echo 0)"
  _t "main --json: tier field" "too-thin" "$(printf '%s' "$e2e_json" | jq -r '.tier')"
  _t "main --json: aggregate.n field" "2" "$(printf '%s' "$e2e_json" | jq -r '.aggregate.n')"

  # ── End-to-end INDETERMINATE via _main() (no bucket matches) ─────────────
  cat > "$mocktmp/goodbin/sqlite3" <<'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF
  chmod +x "$mocktmp/goodbin/sqlite3"
  local ind_out ind_rc
  ind_out=$(PATH="$mocktmp/goodbin:$PATH" AGENTSVIEW_DB="$mocktmp/fake.db" _main "nosuchproject" 2>&1)
  ind_rc=$?
  _t "main: no-bucket-match -> exit 2" "2" "$ind_rc"
  _t "main: no-bucket-match -> INDETERMINATE label" "1" "$(printf '%s' "$ind_out" | grep -q "INDETERMINATE" && echo 1 || echo 0)"
  _t "main: no-bucket-match -> never says too-thin" "0" "$(printf '%s' "$ind_out" | grep -c "too-thin")"

  rm -rf "$mocktmp"

  echo ""
  echo "${pass}/$((pass + fail)) PASS"
  [ "$fail" -eq 0 ] && return 0 || return 1
}

if [ "${1:-}" = "--selftest" ]; then
  _selftest
  exit $?
fi

_main "$@"
exit $?
