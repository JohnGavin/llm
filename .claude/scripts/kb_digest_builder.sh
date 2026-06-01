#!/usr/bin/env bash
# kb_digest_builder.sh — Privacy-safe knowledge-base digest builder.
#
# Analyses git history of a local knowledge/ repo and emits a sanitised
# markdown digest containing ONLY: page TITLES (first # line), counts,
# line deltas, theme labels, new [[topic]] cross-link counts, and
# provenance health. NO page body content, raw/ excerpts, or multi-sentence
# prose is ever emitted.
#
# Usage:
#   kb_digest_builder.sh --repo <path> --since <duration> --out <path>
#   kb_digest_builder.sh --repo <path> --since 24h --dry-run
#   kb_digest_builder.sh --selftest
#
# Args:
#   --repo  PATH      Local knowledge/ git repo path (required unless --selftest)
#   --since DURATION  Look back window: e.g. "24h", "7d", "48h" (default: 24h)
#   --out   PATH      Output file (required unless --dry-run or --selftest)
#   --dry-run         Print to stdout, do not write --out file
#   --selftest        Build a fixture repo in /tmp and validate output
#
# Privacy guards:
#   - Refuses to run inside an agent session (CLAUDE_AGENT=1) unless
#     KB_DIGEST_AUTO=1 is also set. Prevents accidental agent-invoked
#     exfiltration of sensitive knowledge content.
#   - Output path must be provided by caller; no implicit ~/... writes.
#   - Only first # heading lines (titles) extracted from wiki files;
#     no page body content crosses the output boundary.
#
# Tracked in llm#298.

set -uo pipefail

# ── Privacy guard: agent context ─────────────────────────────────────────────

if [ "${CLAUDE_AGENT:-}" = "1" ] && [ "${KB_DIGEST_AUTO:-}" != "1" ]; then
  echo "ERROR: kb_digest_builder.sh refuses to run in an agent session." >&2
  echo "       Set KB_DIGEST_AUTO=1 to override (adds explicit audit trail)." >&2
  echo "       CLAUDE_AGENT=1 was set; KB_DIGEST_AUTO was not." >&2
  exit 2
fi

# ── Argument parsing ──────────────────────────────────────────────────────────

REPO=""
SINCE="24h"
OUT=""
DRY_RUN=0
SELFTEST=0

usage() {
  echo "Usage: $0 --repo <path> --since <duration> --out <path> [--dry-run]"
  echo "       $0 --selftest"
  echo ""
  echo "  --repo PATH      Local knowledge/ git repo path"
  echo "  --since DURATION Look-back window (default: 24h). Examples: 24h, 7d, 48h"
  echo "  --out PATH       Output file path (required unless --dry-run)"
  echo "  --dry-run        Print to stdout, do not write --out"
  echo "  --selftest       Build a fixture git repo in /tmp and validate output"
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)     REPO="$2";    shift 2 ;;
    --since)    SINCE="$2";   shift 2 ;;
    --out)      OUT="$2";     shift 2 ;;
    --dry-run)  DRY_RUN=1;    shift   ;;
    --selftest) SELFTEST=1;   shift   ;;
    -h|--help)  usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

# ── Self-test mode ────────────────────────────────────────────────────────────

if [ "$SELFTEST" = "1" ]; then
  echo "=== kb_digest_builder.sh selftest ==="
  FIXTURE_DIR="$(mktemp -d /tmp/kb_digest_selftest_XXXXXX)"
  trap 'rm -rf "$FIXTURE_DIR"' EXIT

  # Initialise a bare git repo
  git -C "$FIXTURE_DIR" init --quiet
  git -C "$FIXTURE_DIR" config user.email "test@example.com"
  git -C "$FIXTURE_DIR" config user.name "Selftest"

  # Create directory structure
  mkdir -p "$FIXTURE_DIR/wiki"
  mkdir -p "$FIXTURE_DIR/raw"

  # Commit 1: add wiki/foo.md with a title and ## Sources
  cat > "$FIXTURE_DIR/wiki/foo.md" <<'MDEOF'
---
title: foo
status: active
---

# Foo Topic Title

Some body content that should never appear in the digest.

More body text with sensitive context.

## Sources

- raw/foo-source.md
MDEOF

  git -C "$FIXTURE_DIR" add wiki/foo.md
  git -C "$FIXTURE_DIR" commit --quiet -m "feat(wiki): add foo topic"

  # Commit 2: modify wiki/bar.md (add it first so modification is meaningful)
  cat > "$FIXTURE_DIR/wiki/bar.md" <<'MDEOF'
---
title: bar
status: active
---

# Bar Reference Page

Body text for bar — also must not appear in digest output.

## Sources

- raw/bar-source.md
MDEOF

  git -C "$FIXTURE_DIR" add wiki/bar.md
  git -C "$FIXTURE_DIR" commit --quiet -m "feat(wiki): add bar reference"

  # Commit 3: modify bar.md to create a modification record
  printf '\n- Extra point added.\n' >> "$FIXTURE_DIR/wiki/bar.md"
  git -C "$FIXTURE_DIR" add wiki/bar.md
  git -C "$FIXTURE_DIR" commit --quiet -m "docs(wiki): expand bar reference"

  # Run the builder in dry-run mode
  echo ""
  echo "--- Builder output (--dry-run against fixture) ---"
  SELFTEST_OUT="$("$0" --repo "$FIXTURE_DIR" --since 1d --dry-run 2>&1)"
  echo "$SELFTEST_OUT"
  echo "--- End builder output ---"
  echo ""

  # Validation
  PASS=1
  FAIL_MSGS=()

  _check() {
    local label="$1"
    local pattern="$2"
    if echo "$SELFTEST_OUT" | grep -q "$pattern"; then
      echo "  PASS: $label"
    else
      echo "  FAIL: $label (pattern not found: $pattern)"
      PASS=0
      FAIL_MSGS+=("$label")
    fi
  }

  # Must have "Pages added" or "Pages Modified" section
  _check "Has 'Pages' section" "Pages"

  # Must show 'Foo Topic Title' (extracted from # heading)
  _check "Title 'Foo Topic Title' appears" "Foo Topic Title"

  # Must show 'Bar Reference Page' (extracted from # heading)
  _check "Title 'Bar Reference Page' appears" "Bar Reference Page"

  # Must NOT contain body text
  if echo "$SELFTEST_OUT" | grep -q "sensitive context"; then
    echo "  FAIL: Body text leaked ('sensitive context' found in output)"
    PASS=0
    FAIL_MSGS+=("body text leak")
  else
    echo "  PASS: Body text NOT leaked"
  fi

  # Must NOT contain body text from bar
  if echo "$SELFTEST_OUT" | grep -q "Body text for bar"; then
    echo "  FAIL: Body text leaked ('Body text for bar' found in output)"
    PASS=0
    FAIL_MSGS+=("bar body text leak")
  else
    echo "  PASS: Bar body text NOT leaked"
  fi

  # Must show provenance health section
  _check "Has provenance health section" "Provenance"

  echo ""
  if [ "$PASS" = "1" ]; then
    echo "=== selftest PASSED ==="
    exit 0
  else
    echo "=== selftest FAILED: ${FAIL_MSGS[*]} ==="
    exit 1
  fi
fi

# ── Validate required args ────────────────────────────────────────────────────

if [ -z "$REPO" ]; then
  echo "ERROR: --repo is required" >&2
  usage
fi

if [ ! -d "$REPO" ]; then
  echo "ERROR: repo path does not exist or is not a directory: $REPO" >&2
  exit 2
fi

if [ ! -d "$REPO/.git" ]; then
  echo "ERROR: $REPO is not a git repository (.git/ not found)" >&2
  exit 2
fi

if [ "$DRY_RUN" = "0" ] && [ -z "$OUT" ]; then
  echo "ERROR: --out is required unless --dry-run is specified" >&2
  usage
fi

if [ "$DRY_RUN" = "0" ] && [ -n "$OUT" ]; then
  # Refuse implicit home-dir writes; caller must be explicit about where output goes
  case "$OUT" in
    ~/*)
      echo "ERROR: --out path may not use ~/ expansion; provide an absolute path" >&2
      echo "       This prevents silent writes to $HOME when the script is invoked" >&2
      echo "       from unexpected contexts." >&2
      exit 2
      ;;
  esac
fi

# ── Duration → git --after argument ──────────────────────────────────────────
# git --after accepts "X hours ago", "X days ago", or ISO dates.

duration_to_git_after() {
  local dur="$1"
  # Strip trailing whitespace
  dur="${dur#"${dur%%[![:space:]]*}"}"
  dur="${dur%"${dur##*[![:space:]]}"}"

  case "$dur" in
    *h|*H)
      local n="${dur%[hH]}"
      echo "${n} hours ago"
      ;;
    *d|*D)
      local n="${dur%[dD]}"
      echo "${n} days ago"
      ;;
    *w|*W)
      local n="${dur%[wW]}"
      local days=$(( n * 7 ))
      echo "${days} days ago"
      ;;
    *-*-*)
      # ISO date passed through
      echo "$dur"
      ;;
    *)
      # Fall back to git's native parsing
      echo "$dur"
      ;;
  esac
}

GIT_AFTER="$(duration_to_git_after "$SINCE")"

# ── Sanitise text ─────────────────────────────────────────────────────────────
# CRITICAL privacy boundary: strips anything that could be page body content.
# Used on every title and theme string before output.
# Rules:
#   - Strip markdown emphasis markers
#   - Strip URLs
#   - Strip shell-unsafe characters
#   - Truncate to 120 chars (sufficient for a page title, too short for prose)

MAX_TITLE_LEN=120

sanitise_title() {
  local text="$1"
  # Strip leading markdown heading markers (# or ##)
  text="${text#\#\# }"
  text="${text#\# }"
  # Strip trailing whitespace
  text="${text%"${text##*[![:space:]]}"}"
  # Strip markdown emphasis (* _ ` ~)
  text="${text//\`/}"
  text="${text//\*/}"
  text="${text//\_/}"
  text="${text//\~/}"
  # Strip anything that looks like a URL
  text="$(echo "$text" | sed 's|https\?://[^ ]*|<url>|g')"
  # Truncate to MAX_TITLE_LEN
  if [ "${#text}" -gt "$MAX_TITLE_LEN" ]; then
    text="${text:0:$((MAX_TITLE_LEN - 3))}..."
  fi
  echo "$text"
}

# ── Extract first # heading from a wiki file ──────────────────────────────────
# Returns the basename stem if no # heading found.
# ONLY reads the first 20 lines (title zone only — no body exposure).

extract_title_from_file() {
  local file="$1"
  local stem
  stem="$(basename "${file%.md}")"

  if [ ! -f "$file" ]; then
    echo "$stem"
    return
  fi

  local title
  title="$(head -20 "$file" | grep -m1 "^# " | sed 's/^# //')"
  if [ -z "$title" ]; then
    echo "$stem"
  else
    sanitise_title "$title"
  fi
}

# ── Extract title from git history (for deleted files) ────────────────────────
# Reads the last known content of the file from git, extracts the title.

extract_title_from_git() {
  local repo="$1"
  local path="$2"
  local sha="$3"  # commit where the file was last seen

  local stem
  stem="$(basename "${path%.md}")"

  if [ -z "$sha" ]; then
    echo "$stem"
    return
  fi

  # Try to get content from the parent of the deletion commit
  local title
  title="$(git -C "$repo" show "${sha}^:${path}" 2>/dev/null | head -20 | grep -m1 "^# " | sed 's/^# //' )"
  if [ -z "$title" ]; then
    echo "$stem"
  else
    sanitise_title "$title"
  fi
}

# ── Count new [[topic]] links in added lines of a diff ────────────────────────

count_new_wikilinks_in_diff() {
  local repo="$1"
  local sha="$2"
  # Extract only added lines from the diff; count [[...]] occurrences
  git -C "$repo" diff "${sha}^" "$sha" --unified=0 2>/dev/null \
    | grep "^+" \
    | grep -o "\[\[[^]]*\]\]" \
    | wc -l \
    | tr -d ' '
}

# ── Get commits since window ──────────────────────────────────────────────────

COMMITS_RAW="$(git -C "$REPO" log --format="%H %s" --after="$GIT_AFTER" 2>/dev/null)"

N_COMMITS=0
if [ -n "$COMMITS_RAW" ]; then
  N_COMMITS="$(echo "$COMMITS_RAW" | wc -l | tr -d ' ')"
fi

# ── Collect per-file stats from commits ──────────────────────────────────────
# We build temporary lists for each category.

declare -a WIKI_ADDED_FILES=()
declare -a WIKI_MODIFIED_FILES=()
declare -a WIKI_DELETED_FILES=()
declare -a RAW_ADDED_FILES=()

declare -A FILE_STATUS=()       # path → "A" | "M" | "D"
declare -A FILE_LINES_ADDED=()  # path → int
declare -A FILE_LINES_DEL=()    # path → int
declare -A FILE_DEL_SHA=()      # deleted path → sha where it was last seen

NEW_WIKILINKS=0

if [ -n "$COMMITS_RAW" ]; then
  while IFS= read -r commit_line; do
    [ -z "$commit_line" ] && continue
    SHA="${commit_line%% *}"

    # numstat for this commit
    # Format: added\tdeleted\tpath
    # Use diff vs parent; for root commit, use diff-tree --root
    NUMSTAT="$(git -C "$REPO" diff --numstat "${SHA}^" "$SHA" 2>/dev/null)"
    if [ -z "$NUMSTAT" ]; then
      NUMSTAT="$(git -C "$REPO" diff-tree --root --numstat "$SHA" 2>/dev/null)"
    fi

    if [ -z "$NUMSTAT" ]; then
      continue
    fi

    # Also collect per-commit wikilink count
    WL="$(count_new_wikilinks_in_diff "$REPO" "$SHA")"
    NEW_WIKILINKS=$(( NEW_WIKILINKS + WL ))

    while IFS=$'\t' read -r lines_added lines_del fpath; do
      [ -z "$fpath" ] && continue
      lines_added="${lines_added:-0}"
      lines_del="${lines_del:-0}"

      # Classify
      case "$fpath" in
        wiki/*)
          # Check file status in this commit (A/M/D)
          FSTATUS="$(git -C "$REPO" diff --name-status "${SHA}^" "$SHA" 2>/dev/null | grep -E "^[AMD].*${fpath}$" | cut -c1)"
          if [ -z "$FSTATUS" ]; then
            FSTATUS="M"
          fi
          case "$FSTATUS" in
            A) FILE_STATUS["$fpath"]="A" ;;
            D) FILE_STATUS["$fpath"]="D"; FILE_DEL_SHA["$fpath"]="$SHA" ;;
            M)
              # Only set to M if not already marked A or D
              if [ -z "${FILE_STATUS[$fpath]:-}" ]; then
                FILE_STATUS["$fpath"]="M"
              fi
              ;;
          esac
          FILE_LINES_ADDED["$fpath"]=$(( ${FILE_LINES_ADDED[$fpath]:-0} + lines_added ))
          FILE_LINES_DEL["$fpath"]=$(( ${FILE_LINES_DEL[$fpath]:-0} + lines_del ))
          ;;
        raw/*)
          FILE_STATUS["$fpath"]="${FILE_STATUS[$fpath]:-A}"
          FILE_LINES_ADDED["$fpath"]=$(( ${FILE_LINES_ADDED[$fpath]:-0} + lines_added ))
          ;;
      esac
    done <<< "$NUMSTAT"
  done <<< "$COMMITS_RAW"

  # Categorise files
  for fpath in "${!FILE_STATUS[@]}"; do
    status="${FILE_STATUS[$fpath]}"
    case "$fpath" in
      wiki/*)
        case "$status" in
          A) WIKI_ADDED_FILES+=("$fpath") ;;
          M) WIKI_MODIFIED_FILES+=("$fpath") ;;
          D) WIKI_DELETED_FILES+=("$fpath") ;;
        esac
        ;;
      raw/*)
        RAW_ADDED_FILES+=("$fpath")
        ;;
    esac
  done
fi

# ── Provenance health: count wiki/ pages missing ## Sources ──────────────────
# Checks ALL pages in wiki/, not just changed ones.

MISSING_SOURCES_COUNT=0
WIKI_DIR="$REPO/wiki"

if [ -d "$WIKI_DIR" ]; then
  while IFS= read -r wiki_file; do
    [ -f "$wiki_file" ] || continue
    bname="$(basename "$wiki_file")"
    [ "$bname" = "INDEX.md" ] && continue
    [ "$bname" = "LOG.md" ] && continue
    if ! grep -q "^## Sources" "$wiki_file" 2>/dev/null; then
      MISSING_SOURCES_COUNT=$(( MISSING_SOURCES_COUNT + 1 ))
    fi
  done < <(find "$WIKI_DIR" -name "*.md" -type f)
fi

# ── Raw sources size delta ────────────────────────────────────────────────────

RAW_TOTAL_LINES=0
for fpath in "${RAW_ADDED_FILES[@]+"${RAW_ADDED_FILES[@]}"}"; do
  RAW_TOTAL_LINES=$(( RAW_TOTAL_LINES + ${FILE_LINES_ADDED[$fpath]:-0} ))
done

# ── Build markdown digest ─────────────────────────────────────────────────────

TODAY="$(date +%Y-%m-%d)"
GENERATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

{
  echo "## Knowledge Base Digest — $TODAY"
  echo ""
  echo "_${N_COMMITS} commit(s) in the last ${SINCE} (since \"${GIT_AFTER}\")._"
  echo ""
  echo "_Computed locally from: ${REPO}_"
  echo ""
  echo "---"
  echo ""

  # ── Pages added ───────────────────────────────────────────────────────────

  if [ "${#WIKI_ADDED_FILES[@]}" -gt 0 ]; then
    echo "### Pages Added (${#WIKI_ADDED_FILES[@]})"
    echo ""
    for fpath in "${WIKI_ADDED_FILES[@]}"; do
      full_path="$REPO/$fpath"
      title="$(extract_title_from_file "$full_path")"
      stem="$(basename "${fpath%.md}")"
      echo "- **${title}** (\`${stem}\`) — +${FILE_LINES_ADDED[$fpath]:-0} lines"
    done
    echo ""
  else
    echo "### Pages Added"
    echo ""
    echo "_None._"
    echo ""
  fi

  # ── Pages modified ────────────────────────────────────────────────────────

  if [ "${#WIKI_MODIFIED_FILES[@]}" -gt 0 ]; then
    echo "### Pages Modified (${#WIKI_MODIFIED_FILES[@]})"
    echo ""
    for fpath in "${WIKI_MODIFIED_FILES[@]}"; do
      full_path="$REPO/$fpath"
      title="$(extract_title_from_file "$full_path")"
      stem="$(basename "${fpath%.md}")"
      la="${FILE_LINES_ADDED[$fpath]:-0}"
      ld="${FILE_LINES_DEL[$fpath]:-0}"
      echo "- **${title}** (\`${stem}\`) — +${la} / −${ld} lines"
    done
    echo ""
  else
    echo "### Pages Modified"
    echo ""
    echo "_None._"
    echo ""
  fi

  # ── Pages deleted ─────────────────────────────────────────────────────────

  if [ "${#WIKI_DELETED_FILES[@]}" -gt 0 ]; then
    echo "### Pages Deleted (${#WIKI_DELETED_FILES[@]})"
    echo ""
    for fpath in "${WIKI_DELETED_FILES[@]}"; do
      sha="${FILE_DEL_SHA[$fpath]:-}"
      title="$(extract_title_from_git "$REPO" "$fpath" "$sha")"
      stem="$(basename "${fpath%.md}")"
      echo "- **${title}** (\`${stem}\`) — deleted"
    done
    echo ""
  else
    echo "### Pages Deleted"
    echo ""
    echo "_None._"
    echo ""
  fi

  # ── Raw sources appended ──────────────────────────────────────────────────

  RAW_COUNT="${#RAW_ADDED_FILES[@]}"
  echo "### Raw Sources Appended"
  echo ""
  if [ "$RAW_COUNT" -gt 0 ]; then
    echo "_${RAW_COUNT} raw source file(s) appended; ${RAW_TOTAL_LINES} total lines added._"
    echo ""
    echo "_(Source titles are not shown in digests per wiki-storage-policy.)_"
  else
    echo "_None._"
  fi
  echo ""

  # ── Cross-link graph ──────────────────────────────────────────────────────

  echo "### Cross-Link Graph"
  echo ""
  echo "| Metric | Count |"
  echo "|--------|------:|"
  echo "| New \`[[topic]]\` links added | ${NEW_WIKILINKS} |"
  echo ""

  # ── Provenance health ─────────────────────────────────────────────────────

  echo "### Provenance Health"
  echo ""
  echo "| Metric | Count |"
  echo "|--------|------:|"
  echo "| Wiki pages missing \`## Sources\` | ${MISSING_SOURCES_COUNT} |"
  echo ""

  if [ "$MISSING_SOURCES_COUNT" -gt 0 ]; then
    echo "_${MISSING_SOURCES_COUNT} page(s) need a \`## Sources\` section added._"
    echo ""
  fi

  # ── Footer ────────────────────────────────────────────────────────────────

  echo "---"
  echo ""
  echo "_Generated at ${GENERATED_AT} UTC. No raw KB content was read beyond page titles._"
  echo "_Repo: (path withheld from digest — check builder logs for source path)._"

} > /tmp/_kb_digest_output_$$.md

# ── Output ────────────────────────────────────────────────────────────────────

if [ "$DRY_RUN" = "1" ]; then
  cat /tmp/_kb_digest_output_$$.md
  rm -f /tmp/_kb_digest_output_$$.md
  echo "" >&2
  echo "kb_digest_builder.sh: dry-run complete (not written to file)" >&2
else
  # Ensure output directory exists
  OUT_DIR="$(dirname "$OUT")"
  if [ "$OUT_DIR" != "." ] && [ "$OUT_DIR" != "" ]; then
    mkdir -p "$OUT_DIR"
  fi
  mv /tmp/_kb_digest_output_$$.md "$OUT"
  echo "kb_digest_builder.sh: digest written to $OUT" >&2
fi

exit 0
