#!/usr/bin/env bash
# private_terms_sync.sh - derive the private-term list and alias map (llm#1386,
# parent llm#1382, privacy layer L0).
#
# Builds, from sources that already exist, two local-only files (mode 600,
# never committed):
#   ${PRIVATE_TERMS_FILE:-$HOME/.config/private_terms.txt}
#       one lowercase term per line; '#' lines are comments. First line:
#       "# private_terms v1 generated=<ISO-8601 UTC> count=<n>". Consumers match
#       terms whole-word, case-insensitive, and refuse a list that lacks the
#       canary term (CANARY below).
#   ${PRIVATE_ALIASES_FILE:-$HOME/.config/private_aliases.tsv}
#       "term<TAB>alias", alias = private-project-NN, stable across runs
#       (existing assignments are kept; new terms take the next number).
#
# Sources (counts per source are printed; term VALUES are never printed):
#   a) the owner's private + internal repos: gh repo list <owner> --visibility
#      private|internal.  gh failure -> exit 3, old files kept.
#   b) local-only projects, two inputs merged:
#      b1 ${PRIVATE_TERMS_EXTRA_DIRS_FILE:-$HOME/.config/private_term_dirs.txt}:
#         optional hand-kept list, one local-only project root per line; the
#         root's basename and the names of its immediate subdirectories become
#         terms.
#      b2 the cached output of `repo_visibility.sh candidates` (override the
#         command with PRIVATE_TERMS_CANDIDATES_CMD; TSV name<TAB>path<TAB>
#         visibility). Rows classified local_only or confidential_by_policy
#         give their name as a term; `private` rows are NOT taken here (source
#         a covers GitHub-private repos). A candidate-derived name is dropped
#         when shorter than PRIVATE_DETAIL_MIN_NAME_LEN (default 6, the
#         constant private_repo_detail_guard.sh uses) or when listed in
#         PRIVATE_DETAIL_STOPLIST_FILE (default private_name_stoplist.txt
#         beside this script). The cache is read, never refreshed here. A
#         candidates call that exits non-zero (never seeded, stale, unreadable)
#         is INDETERMINATE (exit 3, old files kept), never silently zero.
#      A missing b1 file is a warning, and only when b2 also yields no terms.
#      Noise: with PRIVATE_TERMS_NOISE_REPO=<git repo> the sync reports
#      "source b noisy: N", the count of b2 terms whole-word matching more than
#      PRIVATE_TERMS_NOISE_MAX (default 20) tracked files of that repo. It is a
#      warning only, never an exclusion. `--noise-report <repo>` prints the
#      distribution (counts only) and writes nothing.
#   c) ${PRIVATE_TOPICS_FILE:-$HOME/.config/private_topics.txt}: hand-kept,
#      "term<TAB>category", category in phone|home|health|money. Missing =
#      warning. Lines with another category are skipped (counted, not named).
#   d) ${PRIVATE_PATHS_FILE:-$HOME/.config/private_paths.txt}: path-slug
#      fragments, one per line, if present.
#
# Filtering: terms are lowercased, deduped, and dropped when shorter than 4
# characters or on the built-in STOPLIST below (common English words that would
# match everywhere). "jobs" is stoplisted on purpose: it is the mandatory
# top-level key of every GitHub Actions workflow, so a bare-word entry blocked
# ordinary workflow files and prose. Trade-off: a private repo of that exact
# name is no longer matched as a bare term; its absolute path is still caught
# by private_repo_detail_guard.sh.
#
# Thin-list guard: refuse to write (exit 3, keep old files) when the new term
# count is below ${PRIVATE_TERMS_MIN:-10}, or below 70% of the previous file's
# count. --force overrides the drop check only, never the floor.
#
# Usage: private_terms_sync.sh [--dry-run] [--force] | --noise-report <repo>
# Exit codes: 0 written (or dry-run ok), 2 usage, 3 INDETERMINATE (refused).
# No mode ever prints a term value.
set -euo pipefail

CANARY="zzcanaryprivterm7q"
STOPLIST=" this that with from have been were will your they them then than \
what when where which while about after again also because before being \
between both could does doing down each even every first good great here \
into just know like made make many more most much must never only other \
over same should some such take their there these those through under \
until very want well went work would year years test tests data \
docs code file files home main temp public private internal local \
project projects jobs "

OWNER="${PRIVATE_TERMS_OWNER:-JohnGavin}"
TERMS_FILE="${PRIVATE_TERMS_FILE:-$HOME/.config/private_terms.txt}"
ALIASES_FILE="${PRIVATE_ALIASES_FILE:-$HOME/.config/private_aliases.tsv}"
DIRS_FILE="${PRIVATE_TERMS_EXTRA_DIRS_FILE:-$HOME/.config/private_term_dirs.txt}"
TOPICS_FILE="${PRIVATE_TOPICS_FILE:-$HOME/.config/private_topics.txt}"
PATHS_FILE="${PRIVATE_PATHS_FILE:-$HOME/.config/private_paths.txt}"
MIN="${PRIVATE_TERMS_MIN:-10}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAND_MIN_LEN="${PRIVATE_DETAIL_MIN_NAME_LEN:-6}"
CAND_STOPLIST_FILE="${PRIVATE_DETAIL_STOPLIST_FILE:-$SELF_DIR/private_name_stoplist.txt}"
CAND_CMD="${PRIVATE_TERMS_CANDIDATES_CMD:-bash \"$SELF_DIR/repo_visibility.sh\" candidates}"
NOISE_MAX="${PRIVATE_TERMS_NOISE_MAX:-20}"

DRY=0
FORCE=0
NOISE_REPORT=""
USAGE="usage: private_terms_sync.sh [--dry-run] [--force] | --noise-report <repo>"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --force) FORCE=1 ;;
    --noise-report)
      if [ "$#" -lt 2 ]; then echo "$USAGE" >&2; exit 2; fi
      NOISE_REPORT="$2"; shift ;;
    *) echo "$USAGE" >&2; exit 2 ;;
  esac
  shift
done

case "$MIN" in
  ''|*[!0-9]*) echo "usage: PRIVATE_TERMS_MIN must be a non-negative integer" >&2; exit 2 ;;
esac
case "$CAND_MIN_LEN$NOISE_MAX" in
  ''|*[!0-9]*) echo "usage: min name length and noise max must be non-negative integers" >&2; exit 2 ;;
esac

TMPD=$(mktemp -d)
TT=""
TA=""
trap 'rm -rf "$TMPD"; [ -z "$TT" ] || rm -f "$TT"; [ -z "$TA" ] || rm -f "$TA"' EXIT

# Normalise stdin: lowercase, strip CR/whitespace, drop short/stoplisted/comment.
normalise() {
  tr '[:upper:]' '[:lower:]' | tr -d '\r' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | while IFS= read -r t || [ -n "$t" ]; do
        if [ -z "$t" ]; then continue; fi
        case "$t" in '#'*) continue ;; esac
        if [ "${#t}" -lt 4 ]; then continue; fi
        case "$STOPLIST" in *" $t "*) continue ;; esac
        printf '%s\n' "$t"
      done
}

count() { wc -l < "$1" | tr -d ' '; }

# b2) candidate-derived names: local_only / confidential_by_policy rows ------
# Writes $TMPD/b2.terms. Exit 3 on a failing candidates call.
derive_candidates() {
  local stop="" name
  : > "$TMPD/b2.raw"
  if ! bash -c "$CAND_CMD" > "$TMPD/cands.tsv" 2> "$TMPD/cands.err"; then
    echo "INDETERMINATE: candidates call failed (cache unseeded, stale or unreadable); keeping previous files" >&2
    exit 3
  fi
  if [ -f "$CAND_STOPLIST_FILE" ]; then
    stop=" $(grep -v '^[[:space:]]*#' "$CAND_STOPLIST_FILE" 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ') "
  fi
  awk -F'\t' '$3 == "local_only" || $3 == "confidential_by_policy" { print $1 }' "$TMPD/cands.tsv" \
    | tr '[:upper:]' '[:lower:]' | tr -d '\r' > "$TMPD/b2.names"
  while IFS= read -r name || [ -n "$name" ]; do
    if [ "${#name}" -lt "$CAND_MIN_LEN" ]; then continue; fi
    case "$stop" in *" $name "*) continue ;; esac
    printf '%s\n' "$name" >> "$TMPD/b2.raw"
  done < "$TMPD/b2.names"
  normalise < "$TMPD/b2.raw" | sort -u > "$TMPD/b2.terms"
}

# Whole-word, case-insensitive match count of each term over a repo's tracked
# files (non-alphanumerics, including _ and -, are boundaries). Read-only.
# Sets NZ (0 files), NLOW (1-5), NHIGH (>5), NMAX (largest), NNOISY (> NOISE_MAX).
noise_measure() { # repo termsfile
  local repo=$1 tf=$2 t pat c
  NZ=0; NLOW=0; NHIGH=0; NMAX=0; NNOISY=0
  git -C "$repo" ls-files -z > "$TMPD/tracked.z" 2>/dev/null || return 1
  while IFS= read -r t || [ -n "$t" ]; do
    pat=$(printf '%s' "$t" | sed -e 's/[][\.*^$+?(){}|\/]/\\&/g')
    c=$( (cd "$repo" && xargs -0 grep -l -i -I -E -- "(^|[^a-zA-Z0-9])${pat}([^a-zA-Z0-9]|$)" < "$TMPD/tracked.z" 2>/dev/null) | wc -l | tr -d ' ')
    if [ "$c" -eq 0 ]; then NZ=$((NZ + 1))
    elif [ "$c" -le 5 ]; then NLOW=$((NLOW + 1))
    else NHIGH=$((NHIGH + 1)); fi
    if [ "$c" -gt "$NMAX" ]; then NMAX=$c; fi
    if [ "$c" -gt "$NOISE_MAX" ]; then NNOISY=$((NNOISY + 1)); fi
  done < "$tf"
}

if [ -n "$NOISE_REPORT" ]; then
  derive_candidates
  if ! noise_measure "$NOISE_REPORT" "$TMPD/b2.terms"; then
    echo "INDETERMINATE: cannot list tracked files of the given repo" >&2
    exit 3
  fi
  echo "candidate-derived terms: $(count "$TMPD/b2.terms")"
  echo "match 0 files: $NZ; 1-5 files: $NLOW; >5 files: $NHIGH; max files for one term: $NMAX"
  echo "would exceed noise threshold ($NOISE_MAX files): $NNOISY"
  exit 0
fi

# a) repos ---------------------------------------------------------------
: > "$TMPD/a.raw"
for vis in private internal; do
  if ! gh repo list "$OWNER" --visibility "$vis" --limit 500 --json name \
      > "$TMPD/gh.json" 2> "$TMPD/gh.err"; then
    echo "INDETERMINATE: gh repo list ($vis) failed; keeping previous files" >&2
    exit 3
  fi
  { grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' "$TMPD/gh.json" || true; } \
    | sed -e 's/^"name"[[:space:]]*:[[:space:]]*"//' -e 's/"$//' >> "$TMPD/a.raw"
done
normalise < "$TMPD/a.raw" | sort -u > "$TMPD/a.terms"

# b) local-only project folders ------------------------------------------
DIRS_MISSING=0
: > "$TMPD/b.raw"
if [ -f "$DIRS_FILE" ]; then
  while IFS= read -r d || [ -n "$d" ]; do
    d="${d%$'\r'}"
    if [ -z "$d" ]; then continue; fi
    case "$d" in '#'*) continue ;; esac
    case "$d" in "~"*) d="$HOME${d#\~}" ;; esac
    basename "$d" >> "$TMPD/b.raw"
    if [ -d "$d" ]; then
      for sub in "$d"/*/; do
        if [ -d "$sub" ]; then basename "$sub" >> "$TMPD/b.raw"; fi
      done
    fi
  done < "$DIRS_FILE"
else
  DIRS_MISSING=1
fi
normalise < "$TMPD/b.raw" | sort -u > "$TMPD/b.terms"
derive_candidates
if [ "$DIRS_MISSING" -eq 1 ] && [ ! -s "$TMPD/b2.terms" ]; then
  echo "warning: extra-dirs file missing and candidates yielded no terms (source b empty)" >&2
fi

# c) hand-kept topics ----------------------------------------------------
: > "$TMPD/c.raw"
BAD_CAT=0
if [ -f "$TOPICS_FILE" ]; then
  while IFS=$'\t' read -r term cat || [ -n "${term:-}" ]; do
    term="${term%$'\r'}"
    if [ -z "${term// }" ]; then continue; fi
    case "$term" in '#'*) continue ;; esac
    cat="${cat:-}"
    cat="${cat%$'\r'}"
    case "$cat" in
      phone|home|health|money) printf '%s\n' "$term" >> "$TMPD/c.raw" ;;
      *) BAD_CAT=$((BAD_CAT + 1)) ;;
    esac
  done < "$TOPICS_FILE"
  if [ "$BAD_CAT" -gt 0 ]; then
    echo "warning: $BAD_CAT topic line(s) skipped: category not phone|home|health|money" >&2
  fi
else
  echo "warning: topics file missing (source c skipped)" >&2
fi
normalise < "$TMPD/c.raw" | sort -u > "$TMPD/c.terms"

# d) path slugs ----------------------------------------------------------
: > "$TMPD/d.raw"
if [ -f "$PATHS_FILE" ]; then
  cat "$PATHS_FILE" > "$TMPD/d.raw"
fi
normalise < "$TMPD/d.raw" | sort -u > "$TMPD/d.terms"

# merge ------------------------------------------------------------------
{ cat "$TMPD/a.terms" "$TMPD/b.terms" "$TMPD/b2.terms" "$TMPD/c.terms" "$TMPD/d.terms"; echo "$CANARY"; } \
  | sort -u > "$TMPD/all.terms"
NEW=$(count "$TMPD/all.terms")

PREV=0
if [ -f "$TERMS_FILE" ]; then
  PREV=$({ grep -vc '^#' "$TERMS_FILE" || true; } | tr -d ' ')
fi

echo "source a (repos): $(count "$TMPD/a.terms")"
echo "source b (dirs): $(count "$TMPD/b.terms")"
echo "source b2 (candidates): $(count "$TMPD/b2.terms")"
if [ -n "${PRIVATE_TERMS_NOISE_REPO:-}" ]; then
  if noise_measure "$PRIVATE_TERMS_NOISE_REPO" "$TMPD/b2.terms"; then
    echo "source b noisy: $NNOISY"
    if [ "$NNOISY" -gt 0 ]; then
      echo "warning: $NNOISY candidate-derived term(s) match more than $NOISE_MAX tracked files (kept, not excluded)" >&2
    fi
  else
    echo "warning: noise check skipped (cannot list tracked files)" >&2
  fi
fi
echo "source c (topics): $(count "$TMPD/c.terms")"
echo "source d (paths): $(count "$TMPD/d.terms")"
echo "total (incl. canary): $NEW; previous: $PREV"

if [ "$NEW" -lt "$MIN" ]; then
  echo "INDETERMINATE: thin list ($NEW < floor $MIN); keeping previous files" >&2
  exit 3
fi
if [ "$PREV" -gt 0 ] && [ $((NEW * 100)) -lt $((PREV * 70)) ] && [ "$FORCE" -ne 1 ]; then
  echo "INDETERMINATE: list shrank from $PREV to $NEW (<70%); keeping previous files (--force to override)" >&2
  exit 3
fi

if [ "$DRY" -eq 1 ]; then
  echo "dry-run: nothing written"
  exit 0
fi

# aliases: keep existing assignments, number new terms after the max ----------
: > "$TMPD/aliases.new"
MAXN=0
if [ -f "$ALIASES_FILE" ]; then
  cp "$ALIASES_FILE" "$TMPD/aliases.prev"
else
  : > "$TMPD/aliases.prev"
fi
while IFS=$'\t' read -r t a || [ -n "${t:-}" ]; do
  n="${a:-}"
  n="${n#private-project-}"
  case "$n" in ''|*[!0-9]*) continue ;; esac
  n=$((10#$n))
  if [ "$n" -gt "$MAXN" ]; then MAXN=$n; fi
done < "$TMPD/aliases.prev"
while IFS= read -r t; do
  if [ "$t" = "$CANARY" ]; then continue; fi
  old=$(awk -F'\t' -v t="$t" '$1 == t { print $2; exit }' "$TMPD/aliases.prev")
  if [ -z "$old" ]; then
    MAXN=$((MAXN + 1))
    old=$(printf 'private-project-%02d' "$MAXN")
  fi
  printf '%s\t%s\n' "$t" "$old" >> "$TMPD/aliases.new"
done < "$TMPD/all.terms"

# atomic writes (temp in the destination dir, then mv) ------------------------
mkdir -p "$(dirname "$TERMS_FILE")" "$(dirname "$ALIASES_FILE")"
TT=$(mktemp "$(dirname "$TERMS_FILE")/.private_terms.XXXXXX")
TA=$(mktemp "$(dirname "$ALIASES_FILE")/.private_aliases.XXXXXX")
chmod 600 "$TT" "$TA"
{
  printf '# private_terms v1 generated=%s count=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$NEW"
  cat "$TMPD/all.terms"
} > "$TT"
cp "$TMPD/aliases.new" "$TA"
mv "$TT" "$TERMS_FILE"
mv "$TA" "$ALIASES_FILE"
TT=""
TA=""
echo "written: $NEW terms"
exit 0
