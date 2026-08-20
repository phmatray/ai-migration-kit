#!/usr/bin/env bash
# skills/merge-pr/scripts/remote-branch-teardown.sh — finish the remote-branch delete that Step 7
# used to assume was already done (#185).
#
# Finding (issue #185, Task 1 — confirmed by reading `pkg/cmd/pr/merge/merge.go`'s `mergeRun` on
# `cli/cli`): gh calls `deleteLocalBranch` before `deleteRemoteBranch`, and the first error
# short-circuits the rest. On the kit's own layout the PR's head branch lives in an
# `implement-issue` worktree, so `deleteLocalBranch`'s `git branch -D <headRefName>` fails — git
# refuses to delete a branch checked out elsewhere — `mergeRun` returns right there, and
# `deleteRemoteBranch` never runs. Step 7's local teardown (Case A/B) recovers the local half; this
# script finishes the remote half instead of assuming Step 5's `--delete-branch` or the repo's
# `delete_branch_on_merge` setting already did.
#
# Decision: this always runs the `ls-remote` check, regardless of what the repo's
# `delete_branch_on_merge` setting says. Reading that setting first would save one round trip on
# the repos that have it on, but the value lives in a profile snapshot that can drift between
# refreshes — a stale "true" would skip a delete that is actually still owed, and a leaked branch
# is permanent while an extra `ls-remote` is one cheap network call. Simplicity and correctness
# both point the same way here, so there is no branch on the setting at all.
#
# Usage: remote-branch-teardown.sh <head-branch> <owner>/<repo>
#   Checks whether <head-branch> still exists on `origin` and deletes it via the GitHub API when it
#   does. Tolerant of the branch already being gone — either before the check (Step 5's
#   --delete-branch, GitHub's own delete_branch_on_merge) or in the race between the check and the
#   delete call (the same 422/404 "Reference does not exist" gh's own deleteRemoteBranch tolerates).
#   Any other delete failure is reported on stderr, not swallowed.
#
# Prints exactly one word to stdout and exits 0 on either non-error outcome: already-gone | deleted
# Exits 2 on a usage/prerequisite error, before touching the network.
# Exits 1 on a genuine delete failure — the branch survived and still needs a human's attention.
set -euo pipefail

usage() {
  echo "usage: remote-branch-teardown.sh <head-branch> <owner>/<repo>" >&2
}

HEAD_BRANCH="${1:-}"
REPO="${2:-}"

if [ -z "$HEAD_BRANCH" ] || [ -z "$REPO" ]; then
  usage
  exit 2
fi

command -v git > /dev/null 2>&1 || {
  echo "remote-branch-teardown: git is missing" >&2
  exit 2
}
command -v gh > /dev/null 2>&1 || {
  echo "remote-branch-teardown: gh is missing" >&2
  exit 2
}

if ! REMOTE_REF=$(git ls-remote --heads origin "$HEAD_BRANCH" 2>&1); then
  echo "remote-branch-teardown: git ls-remote --heads origin '$HEAD_BRANCH' failed: $REMOTE_REF" >&2
  exit 1
fi

if [ -z "$REMOTE_REF" ]; then
  echo "already-gone"
  exit 0
fi

if ERR=$(gh api -X DELETE "repos/$REPO/git/refs/heads/$HEAD_BRANCH" 2>&1); then
  echo "deleted"
  exit 0
fi

# Same tolerance gh's own deleteRemoteBranch() applies: 422 (the common case) or 404 both mean
# "Reference does not exist" — a concurrent delete_branch_on_merge or a slow --delete-branch won
# this race between the ls-remote above and this call. Anything else is a real failure.
if printf '%s' "$ERR" | grep -qE 'HTTP (422|404)|Reference does not exist'; then
  echo "already-gone"
  exit 0
fi

echo "remote-branch-teardown: failed to delete origin/$HEAD_BRANCH: $ERR" >&2
exit 1
