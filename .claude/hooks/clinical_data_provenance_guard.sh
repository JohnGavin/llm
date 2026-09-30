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
# (AGENTS.md, "ALL PROJECTS") already existed to prevent. That rule's wording
# didn't name Artifacts/dashboards as a prohibited output target, and no
# PreToolUse hook existed on the `Artifact` matcher checking for this shape
# of content at all — this hook is the first layer closing that second gap.
# Companion rule-text fix: the `Reproducible Ingestion` bullet in AGENTS.md.
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
# JohnGavin/llm is a PUBLIC repo: every value in the selftest fixtures below
# is synthetic by design (e.g. 99.99, 999 — magnitudes no real lab result
# would report) and chosen only to preserve each case's detection SHAPE
# (value+unit, analyte-word+number, mid-line position, unreadable file).
# None of these numbers came from, or resemble, any real clinical result.
#
# Self-test: bash clinical_data_provenance_guard.sh --selftest
#
# Rule: AGENTS.md, "Reproducible Ingestion (ALL PROJECTS)"

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
# Units must end at a word boundary. Most match in any case (mmol/l, ng/ml);
# only the short ambiguous ones, fL and pg, are case-sensitive, so ordinary
# words after a number ("5 pages", "3 floors") never read as units.
UNIT_RE = re.compile(
    r'(?<!\d)(\d*\.)?\d+\s*'
    r'((?i:g/L|mg/L|mmol/L|[uµ]mol/L|x10\^9/L|x10\^12/L|IU/L|mIU/L|'
    r'ng/mL|pmol/L|nmol/L|mL/min)|fL|pg)'
    r'(?![A-Za-z])',
)
# Analyte names match in any case; abbreviations only in upper case, so the
# HTML attribute alt= or the word "cast" cannot match ALT or AST.
#
# The word must be followed by a VALUE SHAPE, not merely any digit within 40
# characters: optional plural, separators (space : = - ( ), optional filler
# words (was/is/of/at/level/result...), optional comparator, then a digit.
# So "creatinine was 999", "ALT = 999", "Sodium: <5" warn, while a CSS class
# or selector ("sodium-icon" ... "3 items", ".potassium{margin:5px}") stays
# silent. Tradeoff, stated openly: a unit-less value with other words in
# between ("creatinine (umol) 999") is now a false negative (a value with a
# unit is still caught by UNIT_RE), and a nutrition line like "Sodium 2
# servings" still warns -- a number directly after the word is exactly the
# shape of a transcribed value and cannot be told apart by form alone.
COMPONENT_RE = re.compile(
    r'(?:(?i:neutrophil|monocyte|lymphocyte|h[ae]emoglobin|platelet|creatinine|'
    r'immunoglobulin|bilirubin|potassium|sodium|calcium|\begfr\b)(?:s|es)?|'
    r'\b(?:IgG|IgA|IgM|CRP|ESR|ALT|AST|PSA)\b)'
    r'[\s:=\-–(]*'
    r'(?:(?i:was|is|of|at|now|levels?|results?|value|reading)\b[\s:=\-–]*)*'
    r'[<>≤≥~]?\s*\d',
)
# Tag stripping (so markup never matches, and visible attribute text does).
# A tag is "<" + letter-led name + ZERO OR MORE well-formed attributes + ">".
# Requiring well-formed attributes (name, optionally =value) is what keeps
# "x<y 99.99 mg/L >" and "<ULN 999 mg/L>" as text: their content is not an
# attribute list, so they are not tags. Tradeoff: a malformed real tag is
# left in place (a false positive at worst, e.g. ALT= in it); a real value
# is never deleted (no false negative). Attribute values, quoted OR unquoted,
# are kept: a tooltip is visible page text. Tags may span lines (the
# replacement keeps the newlines so reported line numbers stay right).
_ATTR = (r'\s+[A-Za-z_:@][-\w:.@]*'
         r'(?:\s*=\s*(?:"[^"]*"|\'[^\']*\'|[^\s"\'<>=`]+))?')
TAG_RE = re.compile(r'</?[A-Za-z][A-Za-z0-9-]*(?:%s)*\s*/?>' % _ATTR)
ATTR_VALUE_RE = re.compile(r'=\s*(?:"([^"]*)"|\'([^\']*)\'|([^\s"\'<>=`]+))')
# Comments: only the markers are removed; the body is kept as text, because a
# comment ships in the page and a value in it is still a transcribed value.
# Dropping the body (old behaviour) was a false negative, and its apostrophes
# could pair up as a quote.
COMMENT_MARK_RE = re.compile(r'<!--|--!?>')


def visible_text(content):
    content = COMMENT_MARK_RE.sub(' ', content)

    def repl(t):
        tag = t.group(0)
        vals = ' '.join(a or b or c for a, b, c in ATTR_VALUE_RE.findall(tag))
        return ' %s ' % vals + '\n' * tag.count('\n')

    return TAG_RE.sub(repl, content)


def _utc_ts():
    return datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def _append(path, line):
    try:
        os.makedirs(LOG_DIR, exist_ok=True)
        with open(path, 'a') as fh:
            fh.write(line + '\n')
    except Exception:
        pass  # logging must never block or affect a publish


def warn(file_path, line_num, kind):
    # The matched text itself is never logged or echoed: it may be a real lab
    # value, and the file path plus line number is enough to find it.
    msg = (
        'WARN (clinical_data_provenance_guard): %s line %d looks like it may '
        'contain a hand-transcribed clinical value (%s). Per the '
        'reproducible-ingestion rule, lab/clinical values must be sourced '
        'from the canonical pipeline (queried from the duckdb this session), '
        'never transcribed directly from a letter/PDF/portal screen -- even '
        'when the pipeline is broken and fixing it feels slower. If this '
        'value was already DB-sourced, ignore this warning. Log: %s'
        % (file_path, line_num, kind, LOG_FILE)
    )
    _append(LOG_FILE, '%s\tfile=%s\tline=%d\tsignal=%s' % (_utc_ts(), file_path, line_num, kind))
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
    for line_num, text in enumerate(visible_text(content).splitlines(), start=1):
        if UNIT_RE.search(text):
            warn(file_path, line_num, 'number with a lab unit')
            return
        if COMPONENT_RE.search(text):
            warn(file_path, line_num, 'lab analyte name near a number')
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
#
# All values below are SYNTHETIC (99.99, 999) — chosen to be shapes no real
# lab result would ever report, while preserving the detection shape each
# case exercises. See the header comment for why: this repo is public.
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

  # ── MUST WARN (synthetic values only — see header) ─────────────────────
  printf '<html><body>\n<p>Neutrophils 99.99 x10^9/L (High)</p>\n</body></html>\n' \
    > "$TMP_DIR/with_unit.html"
  _case_warn "value + known lab unit (x10^9/L)" "$TMP_DIR/with_unit.html"

  printf '<html><body>\n<p>Latest creatinine was 999 - kidneys are fine.</p>\n</body></html>\n' \
    > "$TMP_DIR/with_component.html"
  _case_warn "known lab component name near a number, no unit" "$TMP_DIR/with_component.html"

  printf 'line1\nline2\nHaemoglobin 999 g/L (Low)\nline4\n' > "$TMP_DIR/mid_line.html"
  _case_warn "match on a non-first line is still found (line number tracked)" "$TMP_DIR/mid_line.html"

  printf '<p>Hb 99 mmol/l, Ferritin 50 ng/ml</p>\n' > "$TMP_DIR/lower_unit.html"
  _case_warn "lower-case spelling of an unambiguous unit (mmol/l)" "$TMP_DIR/lower_unit.html"

  printf '<p>Result < 999 mg/L, see > notes</p>\n' > "$TMP_DIR/comparator.html"
  _case_warn "comparator < ... > around a value is not taken as a tag" "$TMP_DIR/comparator.html"

  printf '<span title="Hb 99.99 g/L">x</span>\n' > "$TMP_DIR/tooltip.html"
  _case_warn "value inside a quoted attribute (tooltip) is still seen" "$TMP_DIR/tooltip.html"

  printf '<p>Hb99 g/L</p>\n' > "$TMP_DIR/glued.html"
  _case_warn "value glued to a preceding letter (Hb99 g/L)" "$TMP_DIR/glued.html"

  printf '<p>ALT 999</p>\n' > "$TMP_DIR/upper_alt.html"
  _case_warn "upper-case ALT abbreviation near a number" "$TMP_DIR/upper_alt.html"

  # roborev 13848: tag stripping must not eat real values, nor keep markup.
  printf '<p>x<y 99.99 mg/L ></p>\n' > "$TMP_DIR/lt_not_tag.html"
  _case_warn "x<y 99.99 mg/L > is text with a comparator, not a tag" "$TMP_DIR/lt_not_tag.html"

  printf '<p>Result <ULN 999 mg/L></p>\n' > "$TMP_DIR/uln.html"
  _case_warn "<ULN 999 mg/L> (non-attribute content) is not stripped as a tag" "$TMP_DIR/uln.html"

  printf '<span title=99.99mg/L>x</span>\n' > "$TMP_DIR/unquoted_attr.html"
  _case_warn "unquoted attribute value is kept, like a quoted one" "$TMP_DIR/unquoted_attr.html"

  printf '<!-- Hb 99.99 g/L, don'"'"'t publish -->\n<p>x</p>\n' > "$TMP_DIR/comment.html"
  _case_warn "value inside an HTML comment (with an apostrophe) is still seen" "$TMP_DIR/comment.html"

  # The warning and the log must name the line, never the value itself.
  TOTAL=$((TOTAL + 1))
  GUARD_LOG="$CLINICAL_GUARD_LOG_DIR/clinical_data_provenance_guard.log"
  : > "$GUARD_LOG"
  out=$(run_guard "$(_payload_for_file "$TMP_DIR/with_unit.html")" 2>&1 1>/dev/null)
  if printf '%s' "$out" | grep -q '99\.99'; then
    printf 'FAIL  matched value echoed in the warning\n'
  elif [ "$(grep -c 'signal=' "$GUARD_LOG")" -ne 1 ]; then
    printf 'FAIL  expected exactly one signal= line in the log from this run\n'
  elif grep -q '99\.99' "$GUARD_LOG"; then
    printf 'FAIL  matched value written to the log\n'
  else
    PASS=$((PASS + 1))
    printf 'PASS  matched value is not echoed or logged\n'
  fi

  # ── MUST STAY SILENT (regression guards — over-warning trains ignoring) ──
  printf '<html><body>\n<h1>My dashboard</h1>\n<p>No clinical values here.</p>\n</body></html>\n' \
    > "$TMP_DIR/clean.html"
  _case_silent "clean published file, no lab-value shapes" "$TMP_DIR/clean.html"

  printf '<html><body>\n<p>Room 555, 2nd floor. Call ext 55.</p>\n</body></html>\n' \
    > "$TMP_DIR/plain_numbers.html"
  _case_silent "plain numbers with no lab unit or component keyword nearby" "$TMP_DIR/plain_numbers.html"

  _case_silent "missing file_path target — fail open, no warn" "$TMP_DIR/does_not_exist_xyz.html"

  _case_silent "file_path points at a directory — fail open, no warn" "$TMP_DIR"

  printf '<html><body>\n<img alt="Chart 1" src="c.png"><img ALT="Figure 2">\n</body></html>\n' \
    > "$TMP_DIR/alt_attr.html"
  _case_silent "HTML alt= attribute near a number is markup, not ALT" "$TMP_DIR/alt_attr.html"

  printf '<html><body>\n<p>Read 5 pages (5 pgs), climbed 3 floors, 2 PG, 4 FL, 7 flats.</p>\n</body></html>\n' \
    > "$TMP_DIR/unit_like_words.html"
  _case_silent "ordinary words after a number (pages, floors) are not pg or fL" "$TMP_DIR/unit_like_words.html"

  printf '<img src="c.png"\n  ALT="Figure 2">\n' > "$TMP_DIR/multiline_tag.html"
  _case_silent "multi-line tag carrying an ALT= attribute is stripped whole" "$TMP_DIR/multiline_tag.html"

  printf '<i class="sodium-icon"></i> 3 items\n' > "$TMP_DIR/sodium_icon.html"
  _case_silent "analyte word in a class name, unrelated digit nearby (roborev 13842)" "$TMP_DIR/sodium_icon.html"

  printf '<style>.potassium{margin:5px}</style>\n' > "$TMP_DIR/css_analyte.html"
  _case_silent "analyte word as a CSS selector with a digit in the rule" "$TMP_DIR/css_analyte.html"

  printf 'Hold alt and press 5, or type ast then 9.\n' > "$TMP_DIR/lower_alt.html"
  _case_silent "lower-case alt/ast words are not the ALT/AST abbreviations" "$TMP_DIR/lower_alt.html"

  # Root can read a mode-000 file, so this case only means something as a
  # normal user.
  if [ "$(id -u)" -ne 0 ]; then
    printf 'Neutrophils 99.99 x10^9/L\n' > "$TMP_DIR/unreadable.html"
    chmod 000 "$TMP_DIR/unreadable.html"
    _case_silent "file_path points at an unreadable file — fail open, no warn" "$TMP_DIR/unreadable.html"
    chmod 644 "$TMP_DIR/unreadable.html"
  else
    printf 'SKIP  unreadable-file case (running as root)\n'
  fi

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
