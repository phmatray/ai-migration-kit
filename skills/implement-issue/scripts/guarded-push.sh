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
#   2  REFUSED before pushing — HEAD is another branch, or detached, or not a repo, or this script
#      could not load the branch assertion it shares with guarded-commit.sh. Nothing sent.
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

TOOL=guarded-push
NOTHING="Nothing sent."

# refuse(), usage() and the branch assertion itself live in _assert-branch.sh, shared with
# guarded-commit.sh so the invariant has one home (#44). This bootstrap is deliberately identical
# to that guard's, line for line and comment for comment — it is the part that cannot be shared,
# because it is what loads the shared part, so it is kept mechanical with no prose to drift.
# See guarded-commit.sh for the reasoning behind each step.
SELF="$0"
while [ -L "$SELF" ]; do
  _link=$(readlink -- "$SELF") || break
  case "$_link" in
    /*) SELF="$_link" ;;
    *)  SELF="$(dirname -- "$SELF")/$_link" ;;
  esac
done

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$SELF")" && pwd -P) || SCRIPT_DIR=$(dirname -- "$SELF")
ASSERT="$SCRIPT_DIR/_assert-branch.sh"

if [ -r "$ASSERT" ]; then . "$ASSERT" || true; fi
if ! command -v assert_branch >/dev/null 2>&1 || ! command -v refuse >/dev/null 2>&1; then
  printf '%s: REFUSED — cannot load its branch assertion, so it cannot guard anything:\n  %s\n  %s The guards are not standalone files: reinstall the kit, or restore _assert-branch.sh beside this script.\n' \
    "$TOOL" "$ASSERT" "$NOTHING" >&2
  exit 2
fi

REPO="."
REMOTE="origin"
EXPECTED=""

while [ $# -gt 0 ]; do
  case "$1" in
    -C)        [ -n "${2:-}" ] || refuse "$TOOL" "-C needs a <repo-path>"
               REPO="$2";   shift 2 ;;
    --remote)  [ -n "${2:-}" ] || refuse "$TOOL" "--remote needs a <name>"
               REMOTE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --)        shift; break ;;
    -*)        refuse "$TOOL" "unknown option: $1" ;;
    *)
      [ -z "$EXPECTED" ] || refuse "$TOOL" "unexpected extra argument: $1 (git push args go after --)"
      EXPECTED="$1"; shift ;;
  esac
done

[ -n "$EXPECTED" ] || refuse "$TOOL" "an expected branch name is required: guarded-push.sh [-C <path>] <branch> [-- <git push args…>]"
[ -n "$REMOTE" ]   || refuse "$TOOL" "--remote needs a name"

# ---------------------------------------------------------------- assert, before anything
#
# The checks and their order are in _assert-branch.sh; the prose is here, because what an
# unguarded push costs is not what an unguarded commit costs. `{found}` is the branch HEAD turned
# out to be on. Sets $head_sha — the sha this push must be able to prove reached the remote.

assert_branch "$TOOL" \
  "HEAD is detached in $REPO — it belongs to no branch, so there is nothing safe to push.
            Expected '$EXPECTED'. Nothing sent." \
  "HEAD is on '{found}' but this task owns '$EXPECTED'.
            Pushing now would carry this work into '{found}' and into that branch's
            pull request. Nothing sent. Re-check out '$EXPECTED' (in a worktree of its own)
            and retry."

# The helper tolerates an unreadable HEAD because a COMMIT legitimately has none — an unborn
# branch is where a first commit starts. A PUSH does not: with no sha there is nothing to prove
# reached the remote, and this guard's entire promise is that it can prove it. Sharing the helper
# must not quietly relax that, so require the witness here, BEFORE the write, rather than
# discover its absence afterwards as an exit 4.
[ -n "$head_sha" ] || refuse "$TOOL" \
  "HEAD in $REPO points at no commit — '$EXPECTED' is an unborn branch, so there is nothing
            to push and nothing this guard could verify on the remote. Nothing sent."

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
now_branch=$(head_branch_of "$REPO")
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
#
# The two streams are captured SEPARATELY. Folding them with `2>&1` put whatever git or ssh
# happened to write first onto line 1 of the very variable the sha is parsed out of (#47): the
# `Warning: Permanently added 'github.com' … to the list of known hosts.` of a first SSH
# connection from a fresh machine, container or CI runner, or the `warning: redirecting to
# https://…` of a redirecting HTTPS remote. The guard then compared the word `Warning:` against
# HEAD, found them unequal, and exited 4 — its "the work is not where the exit code implied"
# verdict — on a push that had fully succeeded. That inversion is worse than no guard, because
# this script exists to be the thing the caller believes.
#
# The stderr is still wanted; it is only kept out of the parse. The ALERT below quotes it when
# the listing FAILS, which is what the `2>&1` was there for in the first place.
# Not worth failing a verified push over if mktemp fails — but the ALERT below must then say it
# STOPPED LISTENING rather than report silence, because "git printed nothing" and "we discarded
# what git printed" are different facts and only one of them is observable here.
remote_err_sink=/dev/null
remote_err_captured=0
if remote_err_file=$(mktemp 2>/dev/null); then
  # Registered before anything can write to it, and `rm -f` so a vanished file is not an error
  # under `set -e`. This is the script's only EXIT trap — a second one would silently replace it.
  trap 'rm -f "$remote_err_file"' EXIT
  remote_err_sink="$remote_err_file"
  remote_err_captured=1
fi

set +e
remote_out=$(git -C "$REPO" ls-remote "$REMOTE" "refs/heads/$EXPECTED" 2>"$remote_err_sink")
ls_rc=$?
set -e

if [ "$ls_rc" -ne 0 ]; then
  # Three outcomes, three different sentences. Folding "could not read it back" or "never captured
  # it" into the empty case would print `<git ls-remote printed nothing>` — a claim about git made
  # by a tool that had stopped listening, on the one path whose whole job is to explain the failure.
  if [ "$remote_err_captured" -eq 0 ]; then
    remote_err="<stderr could not be captured: mktemp failed, so git's message is lost, not absent>"
  elif remote_err=$(cat -- "$remote_err_file" 2>/dev/null); then
    [ -n "$remote_err" ] || remote_err="<git ls-remote printed nothing on stderr>"
  else
    remote_err="<stderr was captured but could not be read back from $remote_err_file>"
  fi
  {
    echo "guarded-push: ALERT — git push exited 0, but '$REMOTE' could not be listed, so the"
    echo "              push is UNVERIFIED (git ls-remote exited $ls_rc):"
    printf '%s\n' "$remote_err" | sed 's/^/                  /'
    echo "              Treat the work as unpushed. If the push targeted a different remote,"
    echo "              re-run with --remote <name> so the guard checks the one you wrote to."
  } >&2
  exit 4
fi

# Anchored on the SHAPE of an object id, not on position. `NR==1 {print $1}` trusted the first
# line to be git's answer, and #47 is precisely the case where it is not. `ls-remote` writes
# `<oid><TAB><ref>`; a warning line never has a bare full-length hex first field, so matching the
# shape and taking the first hit skips any preamble that still reaches this variable. The length
# test admits sha-256 repositories (64) alongside sha-1 (40) — a literal `{40}` would have turned
# every push from a sha-256 repository into an exit 4.
#
# Fed by a here-string, NOT by `printf … | awk`: `exit` closes the pipe while the writer may still
# hold data, and under `set -o pipefail` that SIGPIPE becomes the substitution's status — 141 —
# out here, where the `set +e` window has already closed. A verified push would abort with the code
# callers are told means "git push itself failed. Nothing else was done." The kit already names
# this trap in tests/xunit-v3/test.sh; a here-string has no writer to kill.
remote_sha=$(awk '$1 ~ /^[0-9a-f]+$/ && (length($1) == 40 || length($1) == 64) { print $1; exit }' \
  <<<"$remote_out")

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
