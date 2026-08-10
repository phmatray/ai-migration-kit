#!/usr/bin/env bash
# guarded-push.sh — push from the branch you named, then prove the remote actually took it.
#
# Replaces the bare call implement-issue used to make:
#
#     git push            /     git push -u origin <branch>
#
# Measured failure mode of that call (#26, incident of 2026-08-10): HEAD had been moved to
# another agent's branch by a concurrent `git checkout`, so the push carried this task's commit
# into THAT branch's pull request. It exited 0. `git push -u` even printed the reassuring
# "branch … set up to track …" line. A zero exit from git push means "the transfer git decided
# to do, did not error" — it is not a receipt saying your HEAD is now the tip of your branch on
# the remote. Those are different claims, and only the second one is the one worth making.
#
# So: assert HEAD before pushing, and afterwards read the remote back and require it to equal
# this HEAD. The read-back is a ref lookup (`git ls-remote`), not a fetch — no objects move,
# and it asks the remote itself rather than the local remote-tracking ref, which is a cache the
# push under test is what updates.
#
# The branch is taken as an ARGUMENT, never derived from HEAD — deriving it would read the very
# value under suspicion, and would agree with itself no matter which branch was checked out.
#
# Usage:
#   guarded-push.sh [-C <repo-path>] [--remote <name>] <expected-branch> [-- <git push args…>]
#
#   -C <repo-path>   the worktree to push from (default: the current directory). Passed to
#                    `git -C`; the script never `cd`s, so it works from any working directory.
#   --remote <name>  the remote to verify against (default: origin)
#   <expected-branch>  the branch this task owns, spelled out by the caller
#   --               everything after it goes to `git push` verbatim, e.g. `-- -u origin <branch>`
#                    for the first push of a branch that has no upstream yet
#
# Exit codes:
#   0  pushed, and <remote>/<expected-branch> is verified equal to HEAD
#   2  REFUSED before pushing — HEAD is another branch, or detached, or not a repo. Nothing sent.
#   4  the push reported success but the remote does NOT carry this HEAD. This is the silent
#      mis-push: the work is not where the exit code implied it was.
#   *  git push's own exit code, if the push itself failed. Nothing else was done.

set -euo pipefail

refuse() { printf 'guarded-push: REFUSED — %s\n' "$*" >&2; exit 2; }

usage() { sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; }

REPO="."
REMOTE="origin"
EXPECTED=""

while [ $# -gt 0 ]; do
  case "$1" in
    -C)        REPO="${2:-}";   shift 2 ;;
    --remote)  REMOTE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --)        shift; break ;;
    -*)        refuse "unknown option: $1" ;;
    *)
      [ -z "$EXPECTED" ] || refuse "unexpected extra argument: $1 (git push args go after --)"
      EXPECTED="$1"; shift ;;
  esac
done

[ -n "$EXPECTED" ] || refuse "an expected branch name is required: guarded-push.sh [-C <path>] <branch> [-- <git push args…>]"
[ -n "$REMOTE" ]   || refuse "--remote needs a name"
[ -d "$REPO" ]     || refuse "-C path is not a directory: $REPO"

git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 \
  || refuse "not a git repository: $REPO"

# ---------------------------------------------------------------- assert, before anything

# `symbolic-ref` and not `rev-parse --abbrev-ref HEAD`: on a detached HEAD the latter prints
# the literal string "HEAD", which compares as a plain branch name and would sail past a naive
# string test. symbolic-ref simply fails, which is the answer we want.
head_branch=$(git -C "$REPO" symbolic-ref --quiet --short HEAD 2>/dev/null || true)

[ -n "$head_branch" ] || refuse \
  "HEAD is detached in $REPO — it belongs to no branch, so there is nothing safe to push.
            Expected '$EXPECTED'. Nothing sent."

if [ "$head_branch" != "$EXPECTED" ]; then
  refuse "HEAD is on '$head_branch' but this task owns '$EXPECTED'.
            Pushing now would carry this work into '$head_branch' and into that branch's
            pull request. Nothing sent. Re-check out '$EXPECTED' (in a worktree of its own)
            and retry."
fi

head_sha=$(git -C "$REPO" rev-parse HEAD)

# ---------------------------------------------------------------- push

set +e
git -C "$REPO" push "$@"
push_rc=$?
set -e

if [ "$push_rc" -ne 0 ]; then
  printf 'guarded-push: git push failed (exit %s) on %s. Nothing else was done.\n' \
    "$push_rc" "$EXPECTED" >&2
  exit "$push_rc"
fi

# ---------------------------------------------------------------- read the remote back

# A ref listing, not a fetch: no objects are transferred, and it asks the remote rather than
# the local refs/remotes/<remote>/<branch> cache — which is written by the very push whose
# effect is in question, so it cannot serve as the witness for it.
remote_sha=$(git -C "$REPO" ls-remote "$REMOTE" "refs/heads/$EXPECTED" 2>/dev/null | awk 'NR==1 {print $1}')

if [ -z "$remote_sha" ]; then
  {
    echo "guarded-push: ALERT — git push exited 0, but $REMOTE has no '$EXPECTED' to show for it"
    echo "              (or the remote could not be listed). The push is NOT confirmed; treat the"
    echo "              work as unpushed and retry rather than assuming it landed."
  } >&2
  exit 4
fi

if [ "$remote_sha" != "$head_sha" ]; then
  {
    echo "guarded-push: ALERT — git push exited 0, but $REMOTE/$EXPECTED is NOT this HEAD."
    echo "              local  HEAD          $head_sha"
    echo "              remote $REMOTE/$EXPECTED  $remote_sha"
    echo "              The exit code claimed a delivery the remote does not confirm. Check what"
    echo "              was actually pushed and where before doing anything else — and do not"
    echo "              force-push a branch you do not own."
  } >&2
  exit 4
fi

printf 'guarded-push: %s/%s == HEAD (%s), verified on the remote\n' \
  "$REMOTE" "$EXPECTED" "$(git -C "$REPO" rev-parse --short HEAD)"
