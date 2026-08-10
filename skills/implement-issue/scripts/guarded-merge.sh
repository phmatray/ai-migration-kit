#!/usr/bin/env bash
# guarded-merge.sh — merge into the branch you named, and prove the merge landed there.
#
# Replaces the bare call `_shared/sync-with-main.md` used to make, which BOTH lifecycle skills
# read (implement-issue Step 8, merge-pr Step 4):
#
#     git fetch origin main
#     git merge origin/main
#
# Measured failure mode of the sibling calls (#26, incident of 2026-08-10): four agents shared
# one checkout, a concurrent `git checkout` moved HEAD between the branch creation and the
# write, and the write landed on the OTHER agent's branch with every command exiting 0. #30
# guarded the commit and the push. This is the same race on the largest write in the flow: a
# merge commit carries the whole of `main` into whatever branch HEAD happens to name, and
# reverting one out of somebody else's pull request is materially worse than moving a single
# misfiled commit.
#
# The window is also the widest here, which is why guarding only the endpoints is worth MORE
# for a merge than for a commit: `git merge` and the `git commit --no-edit` that completes a
# conflicted merge can be minutes apart, with a human or an agent editing files in between.
# Both ends of that window are guarded — this script for the merge, guarded-commit.sh for the
# completion.
#
# The branch is taken as an ARGUMENT, never derived from HEAD — deriving it would read the very
# value under suspicion, and would agree with itself no matter which branch was checked out.
#
# Usage:
#   guarded-merge.sh [-C <repo-path>] [-c <key>=<value>]… <expected-branch> -- <git merge args…>
#
#   -C <repo-path>  the worktree to merge in (default: the current directory). Passed to
#                   `git -C`; the script never `cd`s, so it works from any working directory.
#   -c <key>=<val>  a git-level config override, repeatable, passed to `git` BEFORE the
#                   subcommand — this is how the commit identity travels to the merge commit
#                   git creates on its own: `-c user.email=… -c user.name="…"`. It cannot go
#                   after `--`: `git merge` has no `-c` of its own and would reject it.
#   <expected-branch>  the branch this task owns, spelled out by the caller
#   --              everything after it goes to `git merge` verbatim (e.g. `origin/main`,
#                   `--abort`, `--continue`, `--no-commit`)
#
# Exit codes:
#   0  merged on <expected-branch>; prints <branch>@<short-sha>
#   2  REFUSED before merging — HEAD is another branch, or detached, or not a repo.
#      Nothing was written.
#   3  the merge was written but HEAD was NOT <expected-branch> afterwards: something moved the
#      branch under this process. The merge commit EXISTS; the message names where it went.
#   5  CONFLICTS — the expected outcome of a real sync, not a failure. HEAD is still on
#      <expected-branch> and the conflicts are left in the working tree for the caller to
#      resolve; complete the merge with `guarded-commit.sh <branch> -- --no-edit`. Never retry
#      the merge blindly on this code.
#   *  git merge's own exit code, if the merge failed for any other reason. Nothing else was
#      done.
#
# Conflicts get a code of their own precisely BECAUSE `git merge` returns 1 for them and for
# unrelated failures alike. Reusing 2 would make "refused, nothing written" ambiguous — the
# defect the review of #30 flagged for git's propagated codes. The witness is not the exit
# code but `git ls-files --unmerged`, read from the index itself.
#
# That is also why every path here prints a line starting `guarded-merge:` — propagating git's
# status is what the contract asks for, but git (or a hook, or a wrapper on $PATH) can itself
# return 2, 3 or 5, which would otherwise be indistinguishable from this script's own verdicts.
# **Read the message, not only the code**: a git failure always says "git merge failed (exit N)".
#
# ⚠ Unlike guarded-commit.sh, this guard does NOT require the branch to advance. "Already up to
# date" is the single most common outcome of a real sync, and `--no-commit`, `--abort` and
# `--quit` all legitimately leave the tip exactly where it was. Requiring an advance would turn
# every one of those into a false alarm, so the receipt reports the tip and lets the caller
# compare. What is asserted is where HEAD is — before and after — which is the claim the
# incident falsified.

set -euo pipefail

refuse() { printf 'guarded-merge: REFUSED — %s\n' "$*" >&2; exit 2; }

# Print the header block, whatever length it happens to be — see guarded-commit.sh for why a
# hardcoded line range is a trap.
usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; }

REPO="."
EXPECTED=""
GIT_OPTS=()

while [ $# -gt 0 ]; do
  case "$1" in
    -C)        [ -n "${2:-}" ] || refuse "-C needs a <repo-path>"
               REPO="$2"; shift 2 ;;
    -c)        [ -n "${2:-}" ] || refuse "-c needs a <key>=<value>"
               GIT_OPTS+=(-c "$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --)        shift; break ;;
    -*)        refuse "unknown option: $1" ;;
    *)
      [ -z "$EXPECTED" ] || refuse "unexpected extra argument: $1 (git merge args go after --)"
      EXPECTED="$1"; shift ;;
  esac
done

[ -n "$EXPECTED" ] || refuse "an expected branch name is required: guarded-merge.sh [-C <path>] <branch> -- <git merge args…>"
[ $# -gt 0 ]       || refuse "no git merge arguments given (expected: -- origin/main)"
[ -d "$REPO" ]     || refuse "-C path is not a directory: $REPO"

git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 \
  || refuse "not a git repository: $REPO"

# ---------------------------------------------------------------- assert, before anything

# `symbolic-ref` and not `rev-parse --abbrev-ref HEAD`: on a detached HEAD the latter prints
# the literal string "HEAD", which compares as a plain branch name and would sail past a naive
# string test. symbolic-ref simply fails, which is the answer we want.
head_branch=$(git -C "$REPO" symbolic-ref --quiet --short HEAD 2>/dev/null || true)

[ -n "$head_branch" ] || refuse \
  "HEAD is detached in $REPO — it belongs to no branch, so this merge has nowhere safe to
             land. Expected '$EXPECTED'. Nothing merged."

if [ "$head_branch" != "$EXPECTED" ]; then
  refuse "HEAD is on '$head_branch' but this task owns '$EXPECTED'.
             Something checked out another branch in $REPO. Merging now would carry the whole
             of the merged ref into '$head_branch' and a later push would deliver it into that
             branch's pull request — the largest write this flow makes, in the wrong place.
             Nothing merged. Re-check out '$EXPECTED' (in a worktree of its own) and retry."
fi

before_sha=$(git -C "$REPO" rev-parse HEAD 2>/dev/null || true)

# ---------------------------------------------------------------- merge

# `${GIT_OPTS[@]+…}` and not a bare `${GIT_OPTS[@]}`: under `set -u`, bash 3.2 (which is what
# /bin/bash still is on macOS) treats an empty array expansion as an unbound variable.
set +e
git -C "$REPO" ${GIT_OPTS[@]+"${GIT_OPTS[@]}"} merge "$@"
merge_rc=$?
set -e

# ---------------------------------------------------------------- assert again, after
#
# Before interpreting git's exit code, find out where HEAD is. A merge that conflicted on
# somebody else's branch is not a conflict to resolve, it is a misfiled write — and the
# conflicted working tree belongs to whoever owns that branch now.

now_branch=$(git -C "$REPO" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
conflicts=$(git -C "$REPO" ls-files --unmerged 2>/dev/null || true)

if [ "$now_branch" != "$EXPECTED" ]; then
  # The sha is printed unconditionally, and FIRST. A detached HEAD is the one case where the
  # merge commit is reachable from no ref at all and will eventually be garbage-collected, so
  # it is precisely the case where withholding the sha loses the work.
  new_sha=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo '<unreadable>')
  expected_now=$(git -C "$REPO" rev-parse --quiet --verify "refs/heads/$EXPECTED" 2>/dev/null || true)
  {
    echo "guarded-merge: ALERT — the merge ran, but HEAD is now '${now_branch:-detached}',"
    echo "               not '$EXPECTED'. HEAD moved while the merge was being written."
    echo "               HEAD is now at: $new_sha"
    if [ -n "$now_branch" ]; then
      echo "               It is on branch '$now_branch'."
    else
      echo "               HEAD is DETACHED, so no branch points at it — it is reachable from"
      echo "               nothing and will be garbage-collected. Save it NOW:"
      echo "                   git -C $REPO branch <rescue-name> $new_sha"
    fi
    if [ "$expected_now" = "$before_sha" ]; then
      echo "               '$EXPECTED' did NOT advance — the merge landed elsewhere."
    fi
    if [ -n "$conflicts" ]; then
      echo "               The working tree also carries unresolved conflicts, and they are now"
      echo "               sitting in '${now_branch:-a detached HEAD}'. Do not resolve them here."
    fi
    echo "               Recover on the branch that took it with"
    echo "                   git -C $REPO merge --abort   (if the merge is still in progress)"
    echo "               or by resetting it to its pre-merge tip — but only if you own that"
    echo "               branch. Never force-push a branch you do not own."
  } >&2
  exit 3
fi

if [ "$merge_rc" -ne 0 ]; then
  # Conflicts are the EXPECTED outcome of a real sync, so they are not folded into git's
  # failure bucket. The index is the witness, not the exit code: `git merge` answers 1 for a
  # conflict and for half a dozen unrelated refusals alike.
  if [ -n "$conflicts" ]; then
    {
      echo "guarded-merge: CONFLICTS on $EXPECTED — this is a normal sync outcome, not a failure."
      echo "               HEAD is still '$EXPECTED' and the conflicted files are in the working"
      echo "               tree. Resolve them, then COMPLETE the merge (do not re-run it):"
      echo "                   guarded-commit.sh -C $REPO <identity> $EXPECTED -- --no-edit"
      echo "               To walk away instead: guarded-merge.sh -C $REPO $EXPECTED -- --abort"
      git -C "$REPO" diff --name-only --diff-filter=U 2>/dev/null | sed 's/^/                   /'
    } >&2
    exit 5
  fi
  printf 'guarded-merge: git merge failed (exit %s) on %s. Nothing else was done.\n' \
    "$merge_rc" "$EXPECTED" >&2
  exit "$merge_rc"
fi

# A zero exit with conflict entries in the index should not be reachable, but "should not" is
# how the incident started. Report it rather than certify it.
if [ -n "$conflicts" ]; then
  {
    echo "guarded-merge: CONFLICTS on $EXPECTED, even though git merge exited 0."
    echo "               Treat the merge as incomplete: resolve, then complete it with"
    echo "                   guarded-commit.sh -C $REPO <identity> $EXPECTED -- --no-edit"
  } >&2
  exit 5
fi

# No "did the branch advance?" assertion here, deliberately — see the ⚠ note in the header.
printf 'guarded-merge: %s@%s\n' "$EXPECTED" "$(git -C "$REPO" rev-parse --short HEAD)"
