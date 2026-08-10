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
#
# That last line is why every path here also prints a line starting `guarded-push:` —
# propagating git's status is what the contract asks for, but git (or a pre-push hook, or a
# wrapper on $PATH) can itself return 2 or 4, which would otherwise be indistinguishable from
# this script's own verdicts. **Read the message, not only the code**: a git failure always says
# "git push failed (exit N)".
#
# ⚠ `--remote` must name the remote the push actually writes to. Verifying `origin` while the
# push args say `-- -u upstream <branch>` would read a ref nobody wrote; that mismatch surfaces
# as exit 4 rather than as a false success, but it is a caller error, not a real divergence.

set -euo pipefail

refuse() { printf 'guarded-push: REFUSED — %s\n' "$*" >&2; exit 2; }

# Print the header block, whatever length it happens to be — see guarded-commit.sh for why a
# hardcoded line range is a trap.
usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; }

REPO="."
REMOTE="origin"
EXPECTED=""

while [ $# -gt 0 ]; do
  case "$1" in
    -C)        [ -n "${2:-}" ] || refuse "-C needs a <repo-path>"
               REPO="$2";   shift 2 ;;
    --remote)  [ -n "${2:-}" ] || refuse "--remote needs a <name>"
               REMOTE="$2"; shift 2 ;;
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

# First: is HEAD still the branch we pushed from? guarded-commit.sh re-asserts after writing and
# this must too. Without it, a checkout landing between the pre-flight assert and `git push` sends
# the OTHER branch (push.default=simple pushes the current one), while the read-back below still
# finds the expected branch sitting at its old tip — which happens to equal the `head_sha` captured
# earlier, so the guard would certify a push it never made.
now_branch=$(git -C "$REPO" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
now_sha=$(git -C "$REPO" rev-parse HEAD 2>/dev/null || true)

if [ "$now_branch" != "$EXPECTED" ] || [ "$now_sha" != "$head_sha" ]; then
  {
    echo "guarded-push: ALERT — git push exited 0, but HEAD moved while it ran."
    echo "              pushed from  $EXPECTED @ $head_sha"
    echo "              HEAD is now  ${now_branch:-detached} @ ${now_sha:-<unreadable>}"
    echo "              git push sends the CURRENT branch, so what reached $REMOTE may not be"
    echo "              your work. Check the remote before pushing again."
  } >&2
  exit 4
fi

# Then: a ref listing, not a fetch — no objects are transferred, and it asks the remote rather
# than the local refs/remotes/<remote>/<branch> cache, which is written by the very push whose
# effect is in question and so cannot serve as the witness for it.
#
# `set +e` around it deliberately: under `set -euo pipefail` a failing `git ls-remote` inside a
# command substitution kills this script on the spot, with git's own status (128) and with stderr
# swallowed — after a push that already succeeded. The caller would read 128 as "the push failed,
# nothing else was done", the exact inversion of what happened, and the ALERT below would be
# unreachable. Verification failing is not the same as verification passing: it is exit 4.
set +e
remote_out=$(git -C "$REPO" ls-remote "$REMOTE" "refs/heads/$EXPECTED" 2>&1)
ls_rc=$?
set -e

if [ "$ls_rc" -ne 0 ]; then
  {
    echo "guarded-push: ALERT — git push exited 0, but '$REMOTE' could not be listed, so the"
    echo "              push is UNVERIFIED (git ls-remote exited $ls_rc):"
    printf '%s\n' "$remote_out" | sed 's/^/                  /'
    echo "              Treat the work as unpushed. If the push targeted a different remote,"
    echo "              re-run with --remote <name> so the guard checks the one you wrote to."
  } >&2
  exit 4
fi

remote_sha=$(printf '%s\n' "$remote_out" | awk 'NR==1 {print $1}')

if [ -z "$remote_sha" ]; then
  {
    echo "guarded-push: ALERT — git push exited 0, but $REMOTE has no '$EXPECTED' to show for it."
    echo "              The push is NOT confirmed; treat the work as unpushed and retry rather"
    echo "              than assuming it landed."
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

# `$head_sha` and not a fresh `rev-parse HEAD`: the receipt must name the sha that was actually
# compared against the remote. Re-reading HEAD here would let the message quote a commit that no
# step ever verified.
printf 'guarded-push: %s/%s == %s, verified on the remote\n' \
  "$REMOTE" "$EXPECTED" "$(git -C "$REPO" rev-parse --short "$head_sha")"
