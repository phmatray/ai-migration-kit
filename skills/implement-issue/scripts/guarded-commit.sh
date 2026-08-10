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
#   2  REFUSED before committing — HEAD is another branch, or detached, or not a repo, or this
#      script could not load the branch assertion it shares with guarded-push.sh.
#      Nothing was written.
#   3  the commit was made but HEAD was NOT <expected-branch> afterwards: something moved the
#      branch under this process. The commit EXISTS; the message names where it went.
#   *  git commit's own exit code, if the commit itself failed. Nothing else was done.
#
# That last line is why every path here also prints a line starting `guarded-commit:` —
# propagating git's status is what the contract asks for, but git (or a pre-commit hook, or a
# wrapper on $PATH) can itself return 2 or 3, which would otherwise be indistinguishable from
# this script's own verdicts. **Read the message, not only the code**: a git failure always says
# "git commit failed (exit N)".

set -euo pipefail

TOOL=guarded-commit
NOTHING="Nothing committed."

# refuse(), usage() and the branch assertion itself live in _assert-branch.sh, so this guard and
# guarded-push.sh share ONE definition of the invariant rather than a copy each (#44). This
# bootstrap is the one part that cannot be shared — it is what loads the shared part — so it is
# kept mechanical: no hand-aligned prose to drift between the two copies.
#
# $0 is resolved through any symlinks first. `pwd -P` canonicalizes the *directory* and never the
# script link itself, so on its own it would send a guard reached through a symlink looking for
# the helper beside the LINK. Before this file existed the guards were self-contained and a
# symlink install worked; keeping that true is the point of this loop. No `readlink -f` — macOS's
# readlink has no -f.
SELF="$0"
while [ -L "$SELF" ]; do
  _link=$(readlink -- "$SELF") || break
  case "$_link" in
    /*) SELF="$_link" ;;
    *)  SELF="$(dirname -- "$SELF")/$_link" ;;
  esac
done

# The `||` fallback is not decoration: this is a plain assignment from a command substitution, so
# under `set -e` a failing cd would kill the script THERE with exit 1 and not a word — and exit 1
# is the code this script documents as "git's own failure", which a caller may read as transient
# and retry. Falling back sends every such case into the refusal below, the path with a test.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$SELF")" && pwd -P) || SCRIPT_DIR=$(dirname -- "$SELF")
ASSERT="$SCRIPT_DIR/_assert-branch.sh"

# Fail CLOSED, in this script's own voice — refuse() is in the file that may be missing.
#
# The test is whether the assertion is CALLABLE, not whether the file is readable: an empty or
# truncated helper (a partial install, an interrupted write, a checkout in flight) is perfectly
# readable, sources without error, and defines nothing — and the first call would then die with
# bash's `command not found`, exit 127, which appears in no exit-code table and so falls into the
# documented "git's own exit code" bucket. That is the misreading this whole block exists to stop.
if [ -r "$ASSERT" ]; then . "$ASSERT" || true; fi
if ! command -v assert_branch >/dev/null 2>&1 || ! command -v refuse >/dev/null 2>&1; then
  printf '%s: REFUSED — cannot load its branch assertion, so it cannot guard anything:\n  %s\n  %s The guards are not standalone files: reinstall the kit, or restore _assert-branch.sh beside this script.\n' \
    "$TOOL" "$ASSERT" "$NOTHING" >&2
  exit 2
fi

REPO="."
EXPECTED=""
GIT_OPTS=()

while [ $# -gt 0 ]; do
  case "$1" in
    -C)        [ -n "${2:-}" ] || refuse "$TOOL" "-C needs a <repo-path>"
               REPO="$2"; shift 2 ;;
    -c)        [ -n "${2:-}" ] || refuse "$TOOL" "-c needs a <key>=<value>"
               GIT_OPTS+=(-c "$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --)        shift; break ;;
    -*)        refuse "$TOOL" "unknown option: $1" ;;
    *)
      [ -z "$EXPECTED" ] || refuse "$TOOL" "unexpected extra argument: $1 (git commit args go after --)"
      EXPECTED="$1"; shift ;;
  esac
done

[ -n "$EXPECTED" ] || refuse "$TOOL" "an expected branch name is required: guarded-commit.sh [-C <path>] <branch> -- <git commit args…>"
[ $# -gt 0 ]       || refuse "$TOOL" "no git commit arguments given (expected: -- -am 'message')"

# ---------------------------------------------------------------- assert, before anything
#
# The checks and their order are in _assert-branch.sh; the prose is here, because what an
# unguarded commit costs is not what an unguarded push costs. `{found}` is the branch HEAD turned
# out to be on. Sets $head_sha, the tip this commit is expected to move.

assert_branch "$TOOL" \
  "HEAD is detached in $REPO — it belongs to no branch, so this commit has nowhere safe to
             land. Expected '$EXPECTED'. Nothing committed." \
  "HEAD is on '{found}' but this task owns '$EXPECTED'.
             Something checked out another branch in $REPO. Committing now would land this
             work on '{found}' and a later push would carry it into that branch's PR.
             Nothing committed. Re-check out '$EXPECTED' (in a worktree of its own) and retry."

# The helper names it $head_sha because that is what it is when it is read. Down here it is the
# tip the branch had BEFORE this commit, and every message below is written in those terms.
before_sha=$head_sha

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
# above and the commit itself. Re-read rather than assume — through the same reader the pre-flight
# used, so the one subtle thing about reading a branch name has one home and not three.
now_branch=$(head_branch_of "$REPO")
expected_now=$(git -C "$REPO" rev-parse --quiet --verify "refs/heads/$EXPECTED" 2>/dev/null || true)

if [ "$now_branch" != "$EXPECTED" ]; then
  # The sha is printed unconditionally, and FIRST. A detached HEAD is the one case where the
  # commit is reachable from no ref at all and will eventually be garbage-collected, so it is
  # precisely the case where withholding the sha loses the work — yet it is also the case where
  # "$now_branch" is empty and a branch-name-shaped message has nothing to say.
  new_sha=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo '<unreadable>')
  {
    echo "guarded-commit: ALERT — the commit was made, but HEAD is now '${now_branch:-detached}',"
    echo "                not '$EXPECTED'. HEAD moved while this commit was being written."
    echo "                The new commit is: $new_sha"
    if [ -n "$now_branch" ]; then
      echo "                It is on branch '$now_branch'."
    else
      echo "                HEAD is DETACHED, so no branch points at it — it is reachable from"
      echo "                nothing and will be garbage-collected. Save it NOW:"
      echo "                    git -C $REPO branch <rescue-name> $new_sha"
    fi
    if [ "$expected_now" = "$before_sha" ]; then
      echo "                '$EXPECTED' did NOT advance — the work is on the wrong branch."
      echo "                Recover by cherry-picking $new_sha onto '$EXPECTED' and reverting it"
      echo "                on '${now_branch:-the branch that took it}'. Never force-push a branch"
      echo "                you do not own."
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
