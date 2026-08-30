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
#   guarded-push.sh [-C <repo-path>] [--remote <name>] [--verify-only] <expected-branch> \
#                   [-- <git push args…>]
#
#   -C <repo-path>   the worktree to push from (default: the current directory). Passed to
#                    `git -C`; the script never `cd`s, so it works from any working directory.
#   --remote <name>  the remote to verify against (default: origin)
#   --verify-only    run the branch assertion and the remote read-back; skip `git push` and the
#                    post-push HEAD re-assert entirely. Nothing is sent. The honest answer to "how
#                    do I re-check after an exit 6?" without re-pushing work that may already be
#                    there (#172). Refuses (exit 2) if combined with `-- <push args…>` — those
#                    would target a push that will never run, and silently dropping them is how a
#                    `--remote`/refspec mismatch becomes invisible. A repeated flag is idempotent.
#   <expected-branch>  the branch this task owns, spelled out by the caller
#   --               everything after it goes to `git push` verbatim, e.g. `-- -u origin <branch>`
#                    for the first push of a branch that has no upstream yet — not usable with
#                    --verify-only, which never pushes
#
# Exit codes:
#   0  pushed, and <remote>/<expected-branch> is verified equal to HEAD
#   2  REFUSED before pushing — HEAD is another branch, or detached, or not a repo, or this script
#      could not load the branch assertion it shares with guarded-commit.sh. Nothing sent.
#   4  the push reported success, and the remote was READ and DISAGREES with it — the one claim
#      this code makes (#172: it no longer also means "the check itself could not run"; that is
#      6, below). Two situations produce it, and both are the remote positively contradicting the
#      push rather than this guard merely failing to certify it:
#
#        a. HEAD moved out from under the push. `git push` sends the CURRENT branch, so what
#           reached <remote> may not be your work. Caught before the remote is read at all — so
#           this one is about your local checkout, and it says nothing about what the remote now
#           holds. Go and look before pushing again.
#           ALERT: `HEAD moved while it ran`.
#        b. <remote> was listed and does not carry this HEAD — the silent mis-push, and the only
#           condition in which the remote positively contradicts the push. Treat the work as
#           unpushed and find out what the branch actually holds before pushing again.
#           ALERT: `is NOT this HEAD`, or `has no '<expected-branch>' to show for it` when the
#           listing came back with no such branch at all.
#   6  the push reported success but this guard could NOT PERFORM the check — <remote> itself
#      could not be listed. VERIFICATION DID NOT RUN. Nothing about the remote was read, so
#      nothing here disproves the push — and nothing here confirms it either. The push exited 0,
#      which is exactly the claim this guard exists not to take on trust: the `--dry-run` and
#      `remote.<name>.push`-refspec cases under 4(b) exit 0 having delivered nothing. So "the
#      work is probably there" is a guess, not a finding. What IS established is that the failure
#      is in the check (a `--remote` naming a remote the push never wrote to, a network drop, an
#      expired credential), not necessarily in the delivery.
#      A code of its own (#172), split out of what used to be a THIRD meaning of exit 4 — on the
#      same principle guarded-merge.sh's exit 5 already applies to conflicts: reusing another
#      condition's number for "I could not determine the answer" makes a caller that branches on
#      the integer unable to tell "refused, nothing written", "disproved", and "not proved either
#      way" apart. guarded-merge.sh's own header states it, and this is that same reasoning with
#      the nouns substituted.
#      Fix the check (the `--remote`, connectivity, credentials), then run this guard again with
#      --verify-only (#172) — that re-checks without pushing again, which is the precise way to
#      find out. A full re-push is also safe (work the remote already holds is a no-op to
#      re-push, and work it does not hold is the outcome you wanted either way), but
#      --verify-only is the more precise of the two, and the only one that costs nothing if the
#      work was never delivered at all.
#      ALERT: `could not be listed` / `push is UNVERIFIED` — the sentence wraps across two
#      lines, so match either half rather than the whole of it.
#   *  git push's own exit code, if the push itself failed. Nothing else was done.
#
# That last line is why every path here also prints a line starting `guarded-push:` —
# propagating git's status is what the contract asks for, but git (or a pre-push hook, or a
# wrapper on $PATH) can itself return 2, 4 or 6, which would otherwise be indistinguishable from
# this script's own verdicts. **Read the message, not only the code**: a git failure always says
# "git push failed (exit N)".
#
# ⚠ `--remote` must name the remote the push actually writes to. Verifying `origin` while the
# push args say `-- -u upstream <branch>` would read a ref nobody wrote; that mismatch surfaces
# as exit 4 (a listable remote that lacks the branch) or exit 6 (an unlistable one) rather than
# as a false success, but it is a caller error, not a real divergence.

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
VERIFY_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    -C)             [ -n "${2:-}" ] || refuse "$TOOL" "-C needs a <repo-path>"
                    REPO="$2";   shift 2 ;;
    --remote)       [ -n "${2:-}" ] || refuse "$TOOL" "--remote needs a <name>"
                    REMOTE="$2"; shift 2 ;;
    --verify-only)  VERIFY_ONLY=1; shift ;;   # idempotent — setting it twice changes nothing
    -h|--help)      usage; exit 0 ;;
    --)             shift; break ;;
    -*)             refuse "$TOOL" "unknown option: $1" ;;
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

# --verify-only skips `git push` entirely (below), so anything after `--` would target a push
# that will never run. Silently dropping those args is how a --remote/refspec mismatch becomes
# invisible — refuse instead, before touching git. Deliberately AFTER the branch/witness asserts
# above, not before: those refuse on the state of THIS checkout regardless of how it was called,
# and must fire first even when the call also carries stray push args.
if [ "$VERIFY_ONLY" -eq 1 ] && [ $# -gt 0 ]; then
  refuse "$TOOL" "--verify-only takes no push arguments — they would target a push that will
            never run under this flag: $*. $NOTHING"
fi

# ---------------------------------------------------------------- push (skipped under --verify-only)
#
# Under --verify-only neither this nor the post-push HEAD re-assert right below runs — there is
# no push to re-assert AFTER, so that condition (HEAD moving mid-push) is structurally
# unreachable here rather than dead code guarded by a flag it forgot to check (#172).

if [ "$VERIFY_ONLY" -eq 0 ]; then
  set +e
  git -C "$REPO" push "$@"
  push_rc=$?
  set -e

  if [ "$push_rc" -ne 0 ]; then
    printf 'guarded-push: git push failed (exit %s) on %s. Nothing else was done.\n' \
      "$push_rc" "$EXPECTED" >&2
    exit "$push_rc"
  fi
fi

# ---------------------------------------------------------------- read the remote back

# First: is HEAD still the branch we pushed from? guarded-commit.sh re-asserts after writing and
# this must too. Without it, a checkout landing between the pre-flight assert and `git push` sends
# the OTHER branch (push.default=simple pushes the current one), while the read-back below still
# finds the expected branch sitting at its old tip — which happens to equal the `head_sha` captured
# earlier, so the guard would certify a push it never made.
#
# Skipped entirely under --verify-only: there is no push to have moved HEAD out from under, so
# nothing here could ever be true — checking anyway would be dead code pretending to be a check.
if [ "$VERIFY_ONLY" -eq 0 ]; then
  # Through head_sha_full_of, which is where this read now has its ONE home (#161) — shared with
  # assert_branch's own pre-flight witness rather than a second copy of `--verify --quiet HEAD`.
  # That is the same spelling the tail of assert_branch() in _assert-branch.sh documents in full: a
  # bare `rev-parse HEAD 2>/dev/null || true` hands back the literal string "HEAD" on an unborn
  # branch. This line once carried that spelling and the ALERT below printed `HEAD is now  wip @
  # HEAD` — a commit an operator could go look up (#92). The verdict was never wrong; the
  # diagnostic was. Cited by function and not by line number, because the file it points at rejects
  # hardcoded line references for exactly the reason they rot.
  now_branch=$(head_branch_of "$REPO")
  now_sha=$(head_sha_full_of "$REPO")

  # The sha field already said `<unreadable>` rather than inventing something (#92). The branch
  # field beside it still said `detached`, which is not the same kind of answer: head_branch_of is
  # empty both for a genuinely detached HEAD and for a path that can no longer be read at all, and
  # after the push nothing here has ruled the second one out — so the line read
  # `HEAD is now  detached @ <unreadable>`, one measured field and one invented (#129).
  #
  # head_state renders it; head_state_unreadable is the shared decision the correction below
  # branches on, kept in _assert-branch.sh rather than written out again here.
  now_state=$(head_state "$REPO" "$now_branch")
  unreadable=0
  if head_state_unreadable "$now_branch" "$now_state"; then unreadable=1; fi

  if [ "$now_branch" != "$EXPECTED" ] || [ "$now_sha" != "$head_sha" ]; then
    {
      echo "guarded-push: ALERT — git push exited 0, but HEAD moved while it ran."
      echo "              pushed from  $EXPECTED @ $head_sha"
      echo "              HEAD is now  $now_state @ ${now_sha:-<unreadable>}"
      if [ "$unreadable" -eq 1 ]; then
        # The correction has to sit here rather than replace the line above, because the line above
        # is still the honest summary of what the guard can no longer confirm.
        echo "              …but that reading is itself unavailable: $REPO can no longer be read as"
        echo "              a git repository, so HEAD may never have moved at all — a worktree"
        echo "              removed or renamed under this command reads exactly the same way."
      fi
      echo "              git push sends the CURRENT branch, so what reached $REMOTE may not be"
      echo "              your work. Check the remote before pushing again."
    } >&2
    exit 4
  fi
fi

# Then: a ref listing, not a fetch — no objects are transferred, and it asks the remote rather
# than the local refs/remotes/<remote>/<branch> cache, which is written by the very push whose
# effect is in question and so cannot serve as the witness for it.
#
# `set +e` around it deliberately: under `set -euo pipefail` a failing `git ls-remote` inside a
# command substitution kills this script on the spot, with git's own status (128) and with stderr
# swallowed — after a push that already succeeded. The caller would read 128 as "the push failed,
# nothing else was done", the exact inversion of what happened, and the ALERT below would be
# unreachable. Verification failing is not the same as verification passing: it is exit 6 — the
# check itself did not run, which is a different claim from "it ran and disagreed" (#172).
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
    # Opening sentence conditional on the mode (#172): under --verify-only no push was ever
    # attempted, so "git push exited 0, but…" would claim something that did not happen — the
    # issue's own Validation rules forbid that sentence outside the mode that made it true.
    if [ "$VERIFY_ONLY" -eq 1 ]; then
      echo "guarded-push: ALERT — '$REMOTE' could not be listed, so --verify-only could not"
      echo "              confirm anything (git ls-remote exited $ls_rc):"
    else
      echo "guarded-push: ALERT — git push exited 0, but '$REMOTE' could not be listed, so the"
      echo "              push is UNVERIFIED (git ls-remote exited $ls_rc):"
    fi
    printf '%s\n' "$remote_err" | sed 's/^/                  /'
    # This sentence, not the reference table, is what a caller actually reads (#93). Saying
    # "treat the work as unpushed" here — the wording used where the remote really does contradict
    # the push (exit 4, below) — sent operators to re-push on the one code that establishes
    # nothing at all. The check failed; the push did not. It now has its own code (6, #172) so a
    # caller branching on the integer alone no longer has to parse this sentence to tell them apart.
    echo "              Do NOT assume the work landed — and do NOT assume it didn't. The CHECK"
    echo "              failed, not necessarily the push. If the push targeted a different remote,"
    echo "              re-run with --remote <name> so the guard checks the one you wrote to."
    # The concrete recovery (#172): --verify-only exists now, so "it has no verify-only mode" is
    # no longer true and would send an operator back to a full re-push for what is, underneath,
    # just a broken read-back.
    if [ "$VERIFY_ONLY" -eq 1 ]; then
      echo "              Fix the check, then run --verify-only again — nothing was pushed either"
      echo "              way, so re-running costs nothing."
    else
      echo "              Fix the check, then re-run with --verify-only (add --remote <name> too"
      echo "              if that was the cause) — it re-checks without pushing again, which is"
      echo "              the precise way to find out. A full re-push is also safe (work the"
      echo "              remote already holds is a no-op to re-push), but --verify-only is the"
      echo "              more precise of the two."
    fi
  } >&2
  exit 6
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

# Reachable under BOTH modes — this is the "remote was read and does not have the branch" claim,
# whether or not this call pushed anything (the --verify-only-on-a-never-pushed-branch edge case,
# #172). The opening clause is conditional for the same reason the exit-6 one is: under
# --verify-only "git push exited 0" would describe a push that never happened.
if [ -z "$remote_sha" ]; then
  {
    if [ "$VERIFY_ONLY" -eq 1 ]; then
      echo "guarded-push: ALERT — --verify-only found $REMOTE has no '$EXPECTED' to show for it."
      echo "              Nothing was pushed by this check; the branch simply is not there."
    else
      echo "guarded-push: ALERT — git push exited 0, but $REMOTE has no '$EXPECTED' to show for it."
      echo "              The push is NOT confirmed; treat the work as unpushed and retry rather"
      echo "              than assuming it landed."
    fi
  } >&2
  exit 4
fi

# Reachable under both modes too — the remote WAS read and disagrees. Same conditional opener.
if [ "$remote_sha" != "$head_sha" ]; then
  {
    if [ "$VERIFY_ONLY" -eq 1 ]; then
      echo "guarded-push: ALERT — --verify-only found $REMOTE/$EXPECTED is NOT this HEAD."
    else
      echo "guarded-push: ALERT — git push exited 0, but $REMOTE/$EXPECTED is NOT this HEAD."
    fi
    echo "              local  HEAD          $head_sha"
    echo "              remote $REMOTE/$EXPECTED  $remote_sha"
    echo "              The remote does not confirm this delivery. Check what was actually pushed"
    echo "              and where before doing anything else — and do not force-push a branch you"
    echo "              do not own."
  } >&2
  exit 4
fi

# `$head_sha` and not a fresh `rev-parse HEAD`: the receipt must name the sha that was actually
# compared against the remote. Re-reading HEAD here would let the message quote a commit that no
# step ever verified.
#
# Abbreviated in its own statement, with a fallback, rather than substituted inline into printf: a
# command substitution that FAILS inside a printf argument is neither caught by `set -e` nor
# reported, so an unreadable repo by this point rendered the guard's strongest claim as
# `origin/a == , verified on the remote` — exit 0, naming no commit at all (measured). That is the
# defect #92 removed from the ALERT above, on the success path, which is the worse place for it.
# The fallback is the full `$head_sha`, which the pre-flight witness check above already required
# to be non-empty — named rather than cited by line, for the reason given at the re-assert.
#
# The read itself is head_sha_of() from _assert-branch.sh, which is where abbreviating a sha now
# lives for all three guards (#129): this line was the third of four spellings, and the fix that
# landed here first stayed here while the two siblings kept theirs — the same "repair it where you
# saw it" shape as #44/#78/#92. head_sha_of takes the <rev> as its second argument, so `$head_sha`
# still names the sha the remote was actually compared against.
short_sha=$(head_sha_of "$REPO" "$head_sha")
printf 'guarded-push: %s/%s == %s, verified on the remote\n' \
  "$REMOTE" "$EXPECTED" "${short_sha:-$head_sha}"
