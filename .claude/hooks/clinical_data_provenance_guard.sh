#!/usr/bin/env bash
#
# clinical_data_provenance_guard.sh — heuristic WARN (never blocks) on
# `Artifact` publishes whose content looks like it contains hand-transcribed
# clinical/lab values, as a reminder to source them from the canonical
# pipeline instead. Hook: PreToolUse:Artifact.
#
# THIS HOOK NEVER BLOCKS: its only exit code is 0. A WARN is a stderr message
# only — same contract as edit_write_similarity_guard.sh, which this mirrors.
# Blocking is deliberately out of scope: this is a content-SHAPE heuristic
# (a number next to a lab unit or component name), not a provenance check —
# it cannot know whether the value was actually queried from a canonical
# duckdb this session or read off a document, so a false positive on a
# correctly DB-sourced dashboard is expected and must never cost a publish.
#
# Source: a private personal-data project, 2026-09-14 — a private prep Artifact
# was populated by reading a released lab-result screen directly and typing
# the values in, instead of via test_results/canonical_observations, because
# the canonical pipeline (tar_make()) was silently broken at the time and
# nobody noticed before falling back to the document. The values happened to
# be correct; the METHOD was the violation the `reproducible-ingestion` rule
# (CLAUDE.md, "ALL PROJECTS") already existed to prevent. That rule's wording
# didn't name Artifacts/dashboards as a prohibited output target, and no
# PreToolUse hook existed on the `Artifact` matcher checking for this shape
# of content at all — this hook is the first layer closing that second gap.
# Companion rule-text fix: the `Reproducible Ingestion` bullet in CLAUDE.md.
#
# This is NOT a substitute for a real provenance check (which would need
# session tool-call history — e.g. "was a Bash command matching duckdb/
# tar_make run before this publish" — a harder, riskier thing to build
# correctly; the same project has an open in-repo issue for the actual
# systemic fix, moving clinic-prep output off hosted Artifacts entirely onto
# a DB-generated local file). Per this repo's own stated philosophy (secret-leak-prevention
# companion doc: "an untested safety hook is worse than a documented gap"),
# this hook stays deliberately narrow and non-blocking rather than reaching
# for a fragile provenance check it cannot verify.
#
# Self-test: bash clinical_data_provenance_guard.sh --selftest
#
# Rule: ~/.claude/CLAUDE.md, "Reproducible Ingestion (ALL PROJECTS)"

set -uo pipefail

PY_CODE=$(cat <<'PYEOF'
import sys, json, os, re, datetime

LOG_DIR = os.environ.get('CLINICAL_GUARD_LOG_DIR') or os.path.expanduser('~/.claude/logs')
LOG_FILE = os.path.join(LOG_DIR, 'clinical_data_provenance_guard.log')

# Same cap the sibling artifact_secret_guard.sh uses — large enough for any
# real artifact page, small enough that a huge file can never stall a publish.
FILE_READ_CAP = 262144

# Two independent signal families. Either alone is enough to warn; neither is
# a credential-shape signal (this hook shares nothing with cred_patterns.py —
# it is a different domain, not a duplicate of the secret guard).
UNIT_RE = re.compile(
    r'\d+(\.\d+)?\s*'
    r'(g/L|mg/L|mmol/L|[uµ]mol/L|x10\^9/L|x10\^12/L|fL|pg|IU/L|mIU/L|'
    r'ng/mL|pmol/L|nmol/L|mL/min)',
    re.IGNORECASE,
)
COMPONENT_RE = re.compile(
    r'(neutrophil|monocyte|lymphocyte|h[ae]emoglobin|platelet|creatinine|'
    r'immunoglobulin|\bIgG\b|\bIgA\b|\bIgM\b|\bCRP\b|\bESR\b|\begfr\b|'
    r'bilirubin|\bALT\b|\bAST\b|potassium|sodium|calcium|\bpsa\b)'
    r'.{0,40}?\d+(\.\d+)?',
    re.IGNORECASE,
)


def _utc_ts():
    return datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def _append(path, line):
    try:
        os.makedirs(LOG_DIR, exist_ok=True)
        with open(path, 'a') as fh:
            fh.write(line + '\n')
    except Exception:
        pass  # logging must never block or affect a publish


def warn(file_path, line_num, sample):
    # NEVER include the raw matched value beyond a short, already-non-secret
    # sample used purely to help the user locate the line -- clinical values
    # are not credentials, but there is no reason to echo more than needed.
    msg = (
        'WARN (clinical_data_provenance_guard): %s line %d looks like it may '
        'contain a hand-transcribed clinical value (%s). Per the '
        'reproducible-ingestion rule, lab/clinical values must be sourced '
        'from the canonical pipeline (queried from the duckdb this session), '
        'never transcribed directly from a letter/PDF/portal screen -- even '
        'when the pipeline is broken and fixing it feels slower. If this '
        'value was already DB-sourced, ignore this warning. Log: %s'
        % (file_path, line_num, sample, LOG_FILE)
    )
    _append(LOG_FILE, '%s\tfile=%s\tline=%d\tsample=%s' % (_utc_ts(), file_path, line_num, sample))
    sys.stderr.write(msg + '\n')


def main():
    raw = sys.stdin.read()
    try:
        data = json.loads(raw)
    except Exception:
        return  # fail open: malformed JSON must never warn or crash
    if not isinstance(data, dict):
        return
    tool_input = data.get('tool_input')
    if not isinstance(tool_input, dict):
        return
    file_path = tool_input.get('file_path')
    if not file_path or not isinstance(file_path, str):
        return  # fail open: nothing to inspect

    content = None
    try:
        path = os.path.expanduser(file_path)
        if os.path.isfile(path):
            with open(path, 'r', errors='replace') as fh:
                content = fh.read(FILE_READ_CAP)
    except Exception:
        content = None  # fail open: unreadable/missing/directory
    if not content:
        return

    # Warn at most once per publish (the first hit is enough to prompt a
    # check; a line-by-line flood would just train the user to ignore it —
    # same "too loud is also broken" lesson as this repo's other guards).
    for line_num, line in enumerate(content.splitlines(), start=1):
        m = UNIT_RE.search(line)
        if m:
            warn(file_path, line_num, m.group(0).strip())
            return
        m = COMPONENT_RE.search(line)
        if m:
            warn(file_path, line_num, m.group(0).strip())
            return


try:
    main()
except SystemExit:
    raise
except Exception:
    pass  # fail-open: any unhandled internal error must never affect a publish
sys.exit(0)
PYEOF
)

run_guard() {
  # $1 = raw stdin JSON. A WARN goes to stderr; stdout is always empty
  # (there is no JSON block payload -- this hook never blocks).
  printf '%s' "$1" | python3 -c "$PY_CODE"
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# SELF-TEST MODE
# ═══════════════════════════════════════════════════════════════════════════
if [ "${1:-}" = "--selftest" ]; then
  TMP_DIR=$(mktemp -d /tmp/clinical_data_provenance_guard_selftest_XXXXXX)
  export CLINICAL_GUARD_LOG_DIR="$TMP_DIR/logs"

  TOTAL=0
  PASS=0

  _payload_for_file() {
    python3 -c 'import json, sys; print(json.dumps({"tool_input": {"file_path": sys.argv[1], "title": "t", "favicon": "x"}}))' "$1"
  }

  _case_warn() {
    local desc="$1" file_path="$2"
    TOTAL=$((TOTAL + 1))
    local payload out
    payload=$(_payload_for_file "$file_path")
    out=$(run_guard "$payload" 2>&1 1>/dev/null)
    if printf '%s' "$out" | grep -q 'WARN (clinical_data_provenance_guard)'; then
      PASS=$((PASS + 1))
      printf 'PASS  [WARN ] %s\n' "$desc"
    else
      printf 'FAIL  [want=WARN got=silent] %s\n' "$desc"
    fi
  }

  _case_silent() {
    local desc="$1" file_path="$2"
    TOTAL=$((TOTAL + 1))
    local payload out
    payload=$(_payload_for_file "$file_path")
    out=$(run_guard "$payload" 2>&1 1>/dev/null)
    if [ -z "$out" ]; then
      PASS=$((PASS + 1))
      printf 'PASS  [SILENT] %s\n' "$desc"
    else
      printf 'FAIL  [want=SILENT got=WARN] %s\n' "$desc"
      printf '      stderr: %s\n' "$out"
    fi
  }

  # ── MUST WARN ──────────────────────────────────────────────────────────
  printf '<html><body>\n<p>Neutrophils 17.32 x10^9/L (High)</p>\n</body></html>\n' \
    > "$TMP_DIR/with_unit.html"
  _case_warn "value + known lab unit (x10^9/L)" "$TMP_DIR/with_unit.html"

  printf '<html><body>\n<p>Latest creatinine was 77 - kidneys are fine.</p>\n</body></html>\n' \
    > "$TMP_DIR/with_component.html"
  _case_warn "known lab component name near a number, no unit" "$TMP_DIR/with_component.html"

  printf 'line1\nline2\nHaemoglobin 128 g/L (Low)\nline4\n' > "$TMP_DIR/mid_line.html"
  _case_warn "match on a non-first line is still found (line number tracked)" "$TMP_DIR/mid_line.html"

  # ── MUST STAY SILENT (regression guards — over-warning trains ignoring) ──
  printf '<html><body>\n<h1>My dashboard</h1>\n<p>No clinical values here.</p>\n</body></html>\n' \
    > "$TMP_DIR/clean.html"
  _case_silent "clean published file, no lab-value shapes" "$TMP_DIR/clean.html"

  printf '<html><body>\n<p>Room 128, 2nd floor. Call ext 17.</p>\n</body></html>\n' \
    > "$TMP_DIR/plain_numbers.html"
  _case_silent "plain numbers with no lab unit or component keyword nearby" "$TMP_DIR/plain_numbers.html"

  _case_silent "missing file_path target — fail open, no warn" "$TMP_DIR/does_not_exist_xyz.html"

  _case_silent "file_path points at a directory — fail open, no warn" "$TMP_DIR"

  printf 'Neutrophils 17.32 x10^9/L\n' > "$TMP_DIR/unreadable.html"
  chmod 000 "$TMP_DIR/unreadable.html"
  _case_silent "file_path points at an unreadable file — fail open, no warn" "$TMP_DIR/unreadable.html"
  chmod 644 "$TMP_DIR/unreadable.html"

  # ── Malformed / absent-key inputs never crash or warn ─────────────────────
  TOTAL=$((TOTAL + 1))
  OUT=$(printf '%s' '{not valid json' | python3 -c "$PY_CODE" 2>&1 1>/dev/null)
  if [ -z "$OUT" ]; then
    PASS=$((PASS + 1))
    printf 'PASS  [SILENT] malformed JSON on stdin does not warn or crash\n'
  else
    printf 'FAIL  [want=SILENT got=%s] malformed JSON on stdin does not warn or crash\n' "$OUT"
  fi

  TOTAL=$((TOTAL + 1))
  PAYLOAD_NOFP=$(python3 -c 'import json; print(json.dumps({"tool_input": {"title": "t"}}))')
  OUT=$(run_guard "$PAYLOAD_NOFP" 2>&1 1>/dev/null)
  if [ -z "$OUT" ]; then
    PASS=$((PASS + 1))
    printf 'PASS  [SILENT] tool_input with no file_path key does not warn\n'
  else
    printf 'FAIL  [want=SILENT got=%s] tool_input with no file_path key does not warn\n' "$OUT"
  fi

  # ── Exit code is ALWAYS 0, even on a WARN — this hook never blocks ───────
  TOTAL=$((TOTAL + 1))
  payload=$(_payload_for_file "$TMP_DIR/with_unit.html")
  printf '%s' "$payload" | python3 -c "$PY_CODE" >/dev/null 2>&1
  RC=$?
  if [ "$RC" -eq 0 ]; then
    PASS=$((PASS + 1))
    printf 'PASS  [EXIT 0] a WARN still exits 0 (never blocks)\n'
  else
    printf 'FAIL  [want=0 got=%d] a WARN still exits 0 (never blocks)\n' "$RC"
  fi

  rm -rf "$TMP_DIR"

  echo ""
  echo "selftest: $PASS/$TOTAL PASS"
  [ "$PASS" -eq "$TOTAL" ] && exit 0
  exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════
# NORMAL HOOK OPERATION
# ═══════════════════════════════════════════════════════════════════════════
INPUT=$(cat)
run_guard "$INPUT"
exit 0
