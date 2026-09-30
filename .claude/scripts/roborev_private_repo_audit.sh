#!/usr/bin/env bash
# roborev_private_repo_audit.sh -- READ-ONLY audit (llm#1296, acceptance item 4).
#
# Lists the repos roborev has registered (its `repos` table) whose root_path the
# shared opt-out guard (git-hooks/lib/roborev_repo_allowed.sh) would now BLOCK:
# marker file, no remote, a locally configured private root, or (opt-in) not on
# the allow-list.
#
# It NEVER writes: the DB is opened with `sqlite3 -readonly`, and nothing is
# deleted. Purging stored reviews/diffs for a blocked repo is the owner's call.
#
# Output is COUNTS ONLY by default, so the result can be quoted without naming
# a private repo. --list additionally prints the blocked root_paths (only use
# it in a terminal you control).
#
# Usage: roborev_private_repo_audit.sh [--list]
# Env:   ROBOREV_DB  (default ~/.roborev/reviews.db)
#        ROBOREV_PRIVATE_ROOTS_FILE / ROBOREV_ALLOWLIST_MODE / ROBOREV_ALLOWED_ROOTS_FILE
#        (see the guard's header)
#
# Exit:  0 = no registered repo would be blocked
#        1 = at least one registered repo would be blocked (counts printed)
#        2 = usage error
#        3 = INDETERMINATE -- the DB/guard could not be read, OR no repo was
#            blocked but some could not be evaluated (checkout gone, so its
#            marker / remote cannot be observed). Never reported as 0.
#
# Ephemeral temp-dir roots (/tmp, /private/tmp, /var/folders) are counted
# separately and excluded: they are phantom registrations (llm#923), not the
# subject of this audit.
set -uo pipefail

LIST=0
case "${1:-}" in
  "") ;;
  --list) LIST=1 ;;
  -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
  *) echo "usage: $0 [--list]" >&2; exit 2 ;;
esac

DB="${ROBOREV_DB:-$HOME/.roborev/reviews.db}"
SQLITE="$(command -v sqlite3 2>/dev/null || true)"
if [ -z "$SQLITE" ]; then
  echo "INDETERMINATE: sqlite3 not found" >&2; exit 3
fi
if [ ! -r "$DB" ]; then
  echo "INDETERMINATE: roborev DB not readable: $DB" >&2; exit 3
fi

_RRA_LIB=""
for _c in "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/../../git-hooks/lib/roborev_repo_allowed.sh" \
          "$HOME/docs_gh/llm/git-hooks/lib/roborev_repo_allowed.sh"; do
  [ -r "$_c" ] && { _RRA_LIB="$_c"; break; }
done
if [ -z "$_RRA_LIB" ]; then
  echo "INDETERMINATE: repo guard (git-hooks/lib/roborev_repo_allowed.sh) not found" >&2; exit 3
fi
# shellcheck disable=SC1090
. "$_RRA_LIB"

ROOTS=$("$SQLITE" -readonly "$DB" "SELECT root_path FROM repos;" 2>/dev/null)
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "INDETERMINATE: could not read repos table (sqlite3 exit $rc)" >&2; exit 3
fi

total=0; ephemeral=0; allowed=0; unverifiable=0
blocked=0; b_marker=0; b_noremote=0; b_private=0; b_allow=0
blocked_paths=""

while IFS= read -r root; do
  [ -n "$root" ] || continue
  total=$((total + 1))
  case "$root" in
    /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*) ephemeral=$((ephemeral + 1)); continue ;;
  esac
  reason=$(roborev_repo_allowed "$root" 2>/dev/null)
  grc=$?
  if [ "$grc" -eq 3 ]; then
    # Checkout gone / not a repo: marker and remote are unobservable, but a
    # private-root match needs only the path text, so still check that.
    if _rra_path_under "${ROBOREV_PRIVATE_ROOTS_FILE:-$HOME/.config/roborev-private-roots}" "$root"; then
      reason="private-root"; grc=1
    else
      unverifiable=$((unverifiable + 1)); continue
    fi
  fi
  if [ "$grc" -eq 0 ]; then
    allowed=$((allowed + 1)); continue
  fi
  blocked=$((blocked + 1))
  case "$reason" in
    marker) b_marker=$((b_marker + 1)) ;;
    noremote) b_noremote=$((b_noremote + 1)) ;;
    private-root) b_private=$((b_private + 1)) ;;
    not-allowlisted) b_allow=$((b_allow + 1)) ;;
  esac
  blocked_paths="${blocked_paths}${reason}	${root}
"
done <<< "$ROOTS"

echo "roborev_private_repo_audit (read-only): registered=$total ephemeral_excluded=$ephemeral allowed=$allowed blocked=$blocked unverifiable=$unverifiable"
echo "  blocked by reason: marker=$b_marker noremote=$b_noremote private-root=$b_private not-allowlisted=$b_allow"
if [ "$LIST" -eq 1 ] && [ -n "$blocked_paths" ]; then
  printf '%s' "$blocked_paths"
fi

if [ "$blocked" -gt 0 ]; then
  echo "FOUND: $blocked registered repo(s) would now be blocked. Purging their stored reviews/diffs is the owner's decision; this script deletes nothing."
  exit 1
fi
if [ "$unverifiable" -gt 0 ]; then
  echo "INDETERMINATE: none blocked, but $unverifiable registered repo(s) could not be evaluated (checkout missing)."
  exit 3
fi
echo "OK: no registered repo would be blocked."
exit 0
