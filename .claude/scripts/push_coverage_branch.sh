#!/usr/bin/env bash
# push_coverage_branch.sh -- publish ONE generated file to a data-only branch.
#
# Usage: push_coverage_branch.sh <file> <branch> [remote]
#   file    repo-relative path of the file to publish (also its path in the tree)
#   branch  branch to push to; the branch tree holds only that file
#   remote  remote name or URL (default: $COVERAGE_PUSH_REMOTE, else origin)
#
# Why: main is protected by a ruleset that github-actions[bot] cannot bypass,
# so coverage.yml no longer commits to main. The commit is built with git
# plumbing on top of the fetched branch tip (root commit when the branch does
# not exist yet), so the working tree, index and HEAD are never touched.
#
# Env: COVERAGE_PUSH_SLEEP_BASE  seconds * attempt between retries (default 10)
#      COVERAGE_PUSH_ATTEMPTS    attempts (default 3)
# The caller must have user.name / user.email configured (or GIT_COMMITTER_*).
#
# Exit: 0 pushed or unchanged, 1 push failed after all attempts,
#       2 usage error, 3 indeterminate (cannot determine remote branch state).
set -euo pipefail

file="${1:-}"
branch="${2:-}"
remote="${3:-${COVERAGE_PUSH_REMOTE:-origin}}"
attempts="${COVERAGE_PUSH_ATTEMPTS:-3}"
sleep_base="${COVERAGE_PUSH_SLEEP_BASE:-10}"

if [ -z "$file" ] || [ -z "$branch" ]; then
  echo "usage: push_coverage_branch.sh <file> <branch> [remote]" >&2
  exit 2
fi
case "$file" in
  /*|../*|*/../*) echo "error: file must be a repo-relative path: $file" >&2; exit 2 ;;
esac
case "$branch" in
  main|master) echo "error: refusing to publish coverage to $branch" >&2; exit 2 ;;
esac
if [ ! -f "$file" ]; then
  echo "error: file not found: $file" >&2
  exit 2
fi

tip_ref="refs/coverage-push/tip"
msg="chore(coverage): update coverage data [skip ci]"
idx="$(mktemp -u "${TMPDIR:-/tmp}/cov-index.XXXXXX")"
trap 'rm -f "$idx"' EXIT

blob="$(git hash-object -w -- "$file")"

attempt=1
while [ "$attempt" -le "$attempts" ]; do
  # Does the branch exist on the remote? ls-remote exit 2 = no match.
  rc=0
  git ls-remote --exit-code --heads "$remote" "refs/heads/$branch" >/dev/null 2>&1 || rc=$?
  parent_args=()
  if [ "$rc" -eq 0 ]; then
    if ! git fetch --quiet "$remote" "+refs/heads/$branch:$tip_ref"; then
      echo "push attempt $attempt: fetch of $branch failed; retrying" >&2
      rc=99
    else
      tip="$(git rev-parse "$tip_ref")"
      old_blob="$(git rev-parse -q --verify "$tip:$file" || true)"
      if [ "$old_blob" = "$blob" ]; then
        echo "$file unchanged on $branch; nothing to push"
        exit 0
      fi
      parent_args=(-p "$tip")
    fi
  elif [ "$rc" -ne 2 ]; then
    echo "push attempt $attempt: ls-remote failed (exit $rc); retrying" >&2
  fi

  if [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ]; then
    rm -f "$idx"
    GIT_INDEX_FILE="$idx" git update-index --add --cacheinfo "100644,$blob,$file"
    tree="$(GIT_INDEX_FILE="$idx" git write-tree)"
    commit="$(git commit-tree "$tree" "${parent_args[@]+"${parent_args[@]}"}" -m "$msg")"
    if git push --quiet "$remote" "$commit:refs/heads/$branch"; then
      echo "pushed $commit to $remote $branch"
      exit 0
    fi
    echo "push attempt $attempt: push rejected; retrying" >&2
  fi

  if [ "$attempt" -lt "$attempts" ]; then
    sleep $((attempt * sleep_base))
  fi
  attempt=$((attempt + 1))
done

echo "::error::could not push $file to $branch after $attempts attempts" >&2
exit 1
