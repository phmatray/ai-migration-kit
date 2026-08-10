#!/usr/bin/env bash
# guarded-commit.sh — commit only onto the branch you named, and prove it landed there.
#
# Replaces the bare call implement-issue used to make:
#
#     git commit -am "<message>"
#
# Measured failure mode of that call (#26, incident of 2026-08-10): four agents shared one
# checkout; a concurrent `git checkout` moved HEAD between the branch creation and the commit;
# the commit landed on the OTHER agent's branch and `git push` carried it into the OTHER
# agent's PR. `git commit` exited 0. `git push` exited 0. `git push -u` even printed the
# expected "branch … set up to track …" line. Nothing anywhere reported a problem — the damage
# was undetectable from the tools that caused it, and was only found by an unrelated
# `git status` afterwards.
#
# `git commit` does not verify you are still on the branch you think you are on. That check has
# to live somewhere, so it lives here: assert HEAD before, commit, assert HEAD again after.
#
# The branch is taken as an ARGUMENT, never derived from HEAD — deriving it would read the very
# value under suspicion, and would agree with itself no matter which branch was checked out.
#
# Usage:
#   guarded-commit.sh [-C <repo-path>] [-c <key>=<value>]… <expected-branch> -- <git commit args…>
#
#   -C <repo-path>  the worktree to commit in (default: the current directory). Passed to
#                   `git -C`; the script never `cd`s, so it works from any working directory.
#   -c <key>=<val>  a git-level config override, repeatable, passed to `git` BEFORE the
#                   subcommand — this is how implement-issue's commit identity travels:
#                   `-c user.email=… -c user.name="…"`. It cannot go after `--`: there it
#                   would reach `git commit`, whose own `-c` means "reuse this commit's
#                   message" and which rejects being combined with -m.
#   <expected-branch>  the branch this task owns, spelled out by the caller
#   --              everything after it goes to `git commit` verbatim (e.g. -am "msg")
#
# Exit codes:
#   0  committed on <expected-branch>; prints <branch>@<short-sha>
#   2  REFUSED before committing — HEAD is another branch, or detached, or not a repo.
#      Nothing was written.
#   3  the commit was made but HEAD was NOT <expected-branch> afterwards: something moved the
#      branch under this process. The commit EXISTS; the message names where it went.
#   *  git commit's own exit code, if the commit itself failed. Nothing else was done.

set -euo pipefail

refuse() { printf 'guarded-commit: REFUSED — %s\n' "$*" >&2; exit 2; }

usage() { sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'; }

REPO="."
EXPECTED=""
GIT_OPTS=()

while [ $# -gt 0 ]; do
  case "$1" in
    -C)        REPO="${2:-}"; shift 2 ;;
    -c)        [ -n "${2:-}" ] || refuse "-c needs a <key>=<value>"
               GIT_OPTS+=(-c "$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --)        shift; break ;;
    -*)        refuse "unknown option: $1" ;;
    *)
      [ -z "$EXPECTED" ] || refuse "unexpected extra argument: $1 (git commit args go after --)"
      EXPECTED="$1"; shift ;;
  esac
done

[ -n "$EXPECTED" ] || refuse "an expected branch name is required: guarded-commit.sh [-C <path>] <branch> -- <git commit args…>"
[ $# -gt 0 ]       || refuse "no git commit arguments given (expected: -- -am 'message')"
[ -d "$REPO" ]     || refuse "-C path is not a directory: $REPO"

git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 \
  || refuse "not a git repository: $REPO"

# ---------------------------------------------------------------- assert, before anything

# `symbolic-ref` and not `rev-parse --abbrev-ref HEAD`: on a detached HEAD the latter prints
# the literal string "HEAD", which compares as a plain branch name and would sail past a naive
# string test. symbolic-ref simply fails, which is the answer we want.
head_branch=$(git -C "$REPO" symbolic-ref --quiet --short HEAD 2>/dev/null || true)

[ -n "$head_branch" ] || refuse \
  "HEAD is detached in $REPO — it belongs to no branch, so this commit has nowhere safe to
             land. Expected '$EXPECTED'. Nothing committed."

if [ "$head_branch" != "$EXPECTED" ]; then
  refuse "HEAD is on '$head_branch' but this task owns '$EXPECTED'.
             Something checked out another branch in $REPO. Committing now would land this
             work on '$head_branch' and a later push would carry it into that branch's PR.
             Nothing committed. Re-check out '$EXPECTED' (in a worktree of its own) and retry."
fi

before_sha=$(git -C "$REPO" rev-parse HEAD 2>/dev/null || true)

# ---------------------------------------------------------------- commit

# `${GIT_OPTS[@]+…}` and not a bare `${GIT_OPTS[@]}`: under `set -u`, bash 3.2 (which is what
# /bin/bash still is on macOS) treats an empty array expansion as an unbound variable.
set +e
git -C "$REPO" ${GIT_OPTS[@]+"${GIT_OPTS[@]}"} commit "$@"
commit_rc=$?
set -e

if [ "$commit_rc" -ne 0 ]; then
  printf 'guarded-commit: git commit failed (exit %s) on %s. Nothing else was done.\n' \
    "$commit_rc" "$EXPECTED" >&2
  exit "$commit_rc"
fi

# ---------------------------------------------------------------- assert again, after

# A successful commit is not proof it landed where you asked: HEAD can move between the check
# above and the commit itself. Re-read rather than assume.
now_branch=$(git -C "$REPO" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
expected_now=$(git -C "$REPO" rev-parse --quiet --verify "refs/heads/$EXPECTED" 2>/dev/null || true)

if [ "$now_branch" != "$EXPECTED" ]; then
  {
    echo "guarded-commit: ALERT — the commit was made, but HEAD is now '${now_branch:-detached}',"
    echo "                not '$EXPECTED'. HEAD moved while this commit was being written."
    if [ -n "$now_branch" ]; then
      echo "                The new commit is at: $now_branch@$(git -C "$REPO" rev-parse --short HEAD)"
    fi
    if [ "$expected_now" = "$before_sha" ]; then
      echo "                '$EXPECTED' did NOT advance — the work is on the wrong branch."
      echo "                Recover by cherry-picking it onto '$EXPECTED' and reverting it on"
      echo "                '${now_branch:-the other branch}'. Never force-push a branch you do not own."
    fi
  } >&2
  exit 3
fi

if [ -n "$before_sha" ] && [ "$expected_now" = "$before_sha" ]; then
  printf 'guarded-commit: ALERT — git commit reported success but %s did not advance (%s).\n' \
    "$EXPECTED" "$(git -C "$REPO" rev-parse --short "$EXPECTED")" >&2
  exit 3
fi

printf 'guarded-commit: %s@%s\n' "$EXPECTED" "$(git -C "$REPO" rev-parse --short HEAD)"
