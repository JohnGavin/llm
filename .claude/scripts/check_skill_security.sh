#!/usr/bin/env bash
# check_skill_security.sh — static security scan for Claude Code skill definitions.
#
# Scans .claude/skills/**/*.md (or supplied paths) for prompt injection,
# permission-bypass, and data-exfiltration patterns. Designed for our skill
# format: Markdown files in .claude/skills/ that give instructions to Claude.
#
# Usage:
#   check_skill_security.sh [options] [path ...]
#
# Options:
#   --format text|json|sarif   output format (default: text)
#   --severity low|medium|high minimum severity to report (default: medium)
#   --diff BASE                scan only skill files changed vs BASE commit
#                              (e.g. --diff origin/main)
#   --fix-hints                print remediation hints per finding
#   --help                     print usage
#
# Exit codes:
#   0 — no findings at or above --severity threshold
#   1 — at least one finding at or above --severity threshold
#   2 — usage/internal error
#
# Tracked in llm#627.

set -euo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

SCRIPT_VERSION="1.0.0"
SKILLS_DIR="${HOME}/docs_gh/llm/.claude/skills"

# ── Defaults ─────────────────────────────────────────────────────────────────
FORMAT="text"
MIN_SEVERITY="medium"
DIFF_BASE=""
FIX_HINTS=0
declare -a TARGETS=()

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --format)    FORMAT="$2";       shift 2 ;;
    --severity)  MIN_SEVERITY="$2"; shift 2 ;;
    --diff)      DIFF_BASE="$2";    shift 2 ;;
    --fix-hints) FIX_HINTS=1;       shift   ;;
    --help)
      sed -n '2,/^# Tracked/p' "$0" | grep '^#' | sed 's/^# \?//'
      exit 0 ;;
    --) shift; TARGETS+=("$@"); break ;;
    -*) echo "Unknown option: $1" >&2; exit 2 ;;
    *)  TARGETS+=("$1"); shift ;;
  esac
done

# Severity rank helper
sev_rank() {
  case "$1" in low) echo 1 ;; medium) echo 2 ;; high) echo 3 ;; *) echo 0 ;; esac
}
MIN_RANK=$(sev_rank "$MIN_SEVERITY")

# ── Collect files ─────────────────────────────────────────────────────────────
declare -a FILES=()

if [[ -n "$DIFF_BASE" ]]; then
  # Only scan skill files changed vs the base commit
  while IFS= read -r f; do
    [[ "$f" == .claude/skills/* && "$f" == *.md ]] && FILES+=("$f")
  done < <(git diff --name-only "${DIFF_BASE}...HEAD" 2>/dev/null || true)
elif [[ ${#TARGETS[@]} -gt 0 ]]; then
  for t in "${TARGETS[@]}"; do
    if [[ -d "$t" ]]; then
      while IFS= read -r f; do FILES+=("$f"); done < <(find "$t" -name "*.md" -type f)
    elif [[ -f "$t" ]]; then
      FILES+=("$t")
    fi
  done
else
  while IFS= read -r f; do FILES+=("$f"); done < <(find "${SKILLS_DIR}" -name "*.md" -type f 2>/dev/null || true)
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "check_skill_security: no skill files to scan" >&2
  exit 0
fi

# ── Pattern definitions ───────────────────────────────────────────────────────
# Format: RULE_ID|severity|grep_pattern|description|remediation_hint
# Patterns are case-insensitive (-i). All are extended regex (-E).
# These match instructions telling Claude to do harmful things.
# NOTE: false positives expected in rule/skill files that document forbidden
# patterns. Review in context; tune patterns as the false-positive rate is
# established (llm#627).
declare -a RULES=(
  "SKL001|high|ignore[[:space:]]+.{0,40}previous[[:space:]]+.{0,40}instruction|Prompt injection — 'ignore previous instructions' pattern|Remove or reframe as a negative example with clear labelling"
  "SKL002|high|exfiltrat[a-z]|Explicit data exfiltration instruction|Remove any instruction to exfiltrate data; this is never valid in a skill"
  "SKL003|high|curl[[:space:]].*-X[[:space:]]*POST[[:space:]].*https?://|POST to external domain in skill body|Move curl examples to a clearly-labelled Forbidden Patterns block, or remove"
  "SKL004|high|SYSTEM[[:space:]]+PROMPT[[:space:]]*:|System-prompt injection marker|Remove; skill files must not contain system-prompt injection syntax"
  "SKL005|medium|bypass[[:space:]]+.{0,40}(permission|hook|guard|safety)[^;.]{0,80}$|Unconditional bypass instruction (not inside a Forbidden block)|Wrap in a '## Forbidden Patterns' heading or remove"
  "SKL006|medium|never[[:space:]]+(tell|inform|reveal|disclose)[[:space:]]+(the[[:space:]]+)?user|Instruction to withhold information from the user|Remove; skills must not instruct Claude to deceive users"
  "SKL007|medium|ignore[[:space:]]+.{0,30}(rule|hook|guard)|Instruction to ignore a safety rule or hook|Reframe as a negative example inside a clearly-labelled Forbidden block"
  "SKL008|low|disable[[:space:]]+.{0,30}hook|Instruction to disable a hook|Document in Forbidden Patterns, not as an imperative"
  "SKL009|low|install\.packages\(|install.packages() in skill — forbidden in Nix|Replace with nix-shell or document as a forbidden pattern"
)

# ── Scan ──────────────────────────────────────────────────────────────────────
declare -a FINDINGS=()

for file in "${FILES[@]}"; do
  [[ -f "$file" ]] || continue
  lineno=0
  while IFS= read -r line; do
    lineno=$((lineno + 1))
    for rule in "${RULES[@]}"; do
      IFS='|' read -r rule_id severity pattern description hint <<< "$rule"
      rank=$(sev_rank "$severity")
      [[ $rank -lt $MIN_RANK ]] && continue
      if echo "$line" | grep -qiE "$pattern" 2>/dev/null; then
        FINDINGS+=("${file}|${lineno}|${rule_id}|${severity}|${description}|${hint}|$(echo "$line" | sed 's/^[[:space:]]*//' | cut -c1-120)")
      fi
    done
  done < "$file"
done

total=${#FINDINGS[@]}

# ── Output ────────────────────────────────────────────────────────────────────
case "$FORMAT" in

  text)
    if [[ $total -eq 0 ]]; then
      echo "check_skill_security: 0 findings (severity >= ${MIN_SEVERITY}) in ${#FILES[@]} files"
      exit 0
    fi
    echo "check_skill_security: ${total} finding(s) in ${#FILES[@]} files (severity >= ${MIN_SEVERITY})"
    echo ""
    for finding in "${FINDINGS[@]}"; do
      IFS='|' read -r f ln rid sev desc hint snippet <<< "$finding"
      echo "  [${sev^^}] ${rid} ${f}:${ln}"
      echo "    ${desc}"
      echo "    snippet: ${snippet}"
      [[ $FIX_HINTS -eq 1 ]] && echo "    hint: ${hint}"
      echo ""
    done
    exit 1
    ;;

  json)
    echo '{"version":"'"${SCRIPT_VERSION}"'","tool":"check_skill_security","min_severity":"'"${MIN_SEVERITY}"'","files_scanned":'"${#FILES[@]}"',"total_findings":'"${total}"',"findings":['
    first=1
    for finding in "${FINDINGS[@]}"; do
      IFS='|' read -r f ln rid sev desc hint snippet <<< "$finding"
      [[ $first -eq 0 ]] && echo ","
      printf '{"rule_id":"%s","severity":"%s","file":"%s","line":%s,"description":"%s","snippet":"%s"}' \
        "$rid" "$sev" "$f" "$ln" "$desc" "$(echo "$snippet" | sed 's/"/\\"/g')"
      first=0
    done
    echo ']}'
    [[ $total -gt 0 ]] && exit 1 || exit 0
    ;;

  sarif)
    # SARIF 2.1.0 minimal output
    # rules array
    rules_json=""
    first=1
    for rule in "${RULES[@]}"; do
      IFS='|' read -r rule_id severity pattern description hint <<< "$rule"
      [[ $first -eq 0 ]] && rules_json+=","
      rules_json+=$(printf '{"id":"%s","name":"%s","shortDescription":{"text":"%s"},"properties":{"severity":"%s"}}' \
        "$rule_id" "$rule_id" "$description" "$severity")
      first=0
    done
    # results array
    results_json=""
    first=1
    for finding in "${FINDINGS[@]}"; do
      IFS='|' read -r f ln rid sev desc hint snippet <<< "$finding"
      [[ $first -eq 0 ]] && results_json+=","
      results_json+=$(printf '{"ruleId":"%s","level":"%s","message":{"text":"%s"},"locations":[{"physicalLocation":{"artifactLocation":{"uri":"%s"},"region":{"startLine":%s}}}]}' \
        "$rid" "$([ "$sev" = "high" ] && echo error || echo warning)" \
        "$(echo "$desc" | sed 's/"/\\"/g')" "$f" "$ln")
      first=0
    done
    cat <<SARIF
{"version":"2.1.0","\$schema":"https://raw.githubusercontent.com/oasis-tcs/sarif-spec/master/Schemata/sarif-schema-2.1.0.json","runs":[{"tool":{"driver":{"name":"check_skill_security","version":"${SCRIPT_VERSION}","rules":[${rules_json}]}},"results":[${results_json}]}]}
SARIF
    [[ $total -gt 0 ]] && exit 1 || exit 0
    ;;

  *)
    echo "Unknown format: ${FORMAT}" >&2
    exit 2
    ;;
esac
