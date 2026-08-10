#!/usr/bin/env bash
# Golden test for guarded-commit.sh / guarded-push.sh — the guarded writes that replace
#   git commit -am "..."   /   git push
# in implement-issue.
#
# Those two commands landed a commit on someone else's branch and pushed it into someone
# else's PR (#26, incident of 2026-08-10). Measured cause: four agents shared one checkout,
# a concurrent `git checkout` moved HEAD between branch creation and commit, and NOTHING
# reported it — `git commit` exited 0, `git push -u` exited 0 and even printed the expected
# "branch … set up to track …" line. The damage was invisible from the tools that caused it.
#
# So every case below must fail CLOSED: refuse, exit non-zero, and leave every branch's
# history exactly as it was — or, where the damage is already done, say so loudly and name
# exactly where the commit went.
set -euo pipefail
cd "$(dirname "$0")/../.."

KIT="$PWD"
COMMIT="$KIT/skills/implement-issue/scripts/guarded-commit.sh"
PUSH="$KIT/skills/implement-issue/scripts/guarded-push.sh"

[ -x "$COMMIT" ] || { echo "FAIL: $COMMIT missing or not executable"; exit 1; }
[ -x "$PUSH" ]   || { echo "FAIL: $PUSH missing or not executable"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# A scratch repo with two branches, `a` and `b`, each carrying one commit; HEAD on `b`.
# Local config only: the ambient user config may sign commits or set a commit template,
# neither of which must reach a test fixture.
new_repo() {
  local d="$WORK/$1"
  git init -q "$d"
  git -C "$d" symbolic-ref HEAD refs/heads/a          # version-proof `git init -b a`
  git -C "$d" config user.email test@example.com
  git -C "$d" config user.name "Guarded Git Test"
  git -C "$d" config commit.gpgsign false
  echo seed > "$d/seed.txt"
  git -C "$d" add seed.txt
  git -C "$d" commit -q -m seed
  git -C "$d" checkout -q -b b
  echo b > "$d/b.txt"
  git -C "$d" add b.txt
  git -C "$d" commit -q -m b
  printf '%s' "$d"
}

# The same scratch repo, plus a LOCAL BARE repo wired up as `origin` and branch `a` already
# pushed with an upstream. Local-only: these tests must never touch the network.
new_repo_with_origin() {
  local d; d=$(new_repo "$1")
  git -C "$d" checkout -q a
  git init -q --bare "$WORK/$1.git"
  git -C "$d" remote add origin "$WORK/$1.git"
  git -C "$d" push -q -u origin a
  printf '%s' "$d"
}

tip() { git -C "$1" rev-parse "refs/heads/$2"; }

# What the REMOTE actually holds — read from the bare repo itself, so the assertion never
# depends on the local remote-tracking ref the push under test is what updates.
remote_tip() { git -C "$WORK/$1.git" rev-parse --quiet --verify "refs/heads/$2" || true; }

# Runs the guard without `set -e` aborting the test, capturing stdout+stderr and the code.
# Sets RC and OUT (a file path).
run() {
  local name="$1"; shift
  OUT="$WORK/out.$name"
  set +e
  "$@" > "$OUT" 2>&1
  RC=$?
  set -e
}

fail() { echo "FAIL [$1]: $2"; shift 2; [ -n "${OUT:-}" ] && sed 's/^/    | /' "$OUT"; exit 1; }

# ---------------------------------------------------------------- 1. the incident itself
#
# implement-issue created and checked out `a`; a concurrent agent then ran `git checkout b`
# in the same checkout; the task's commit followed. Unguarded, that commit landed on `b` and
# the push carried it into `b`'s pull request. Here it must land nowhere.

R=$(new_repo incident)
git -C "$R" checkout -q a                       # the task owns `a` and is sitting on it
git -C "$R" checkout -q b                       # …until a concurrent agent switches HEAD
before_a=$(tip "$R" a); before_b=$(tip "$R" b)
echo "task work" >> "$R/seed.txt"

run incident "$COMMIT" -C "$R" a -- -am "feat: the task's own work"

[ "$RC" -eq 2 ] || fail incident "expected exit 2, got $RC"
[ "$(tip "$R" a)" = "$before_a" ] || fail incident "branch a moved"
[ "$(tip "$R" b)" = "$before_b" ] || fail incident "branch b gained the commit — this IS the bug"
grep -q "'b'" "$OUT" && grep -q "'a'" "$OUT" \
  || fail incident "the refusal must name both the branch found and the branch expected"
echo "  ok: incident — HEAD switched to b behind the task; refused (2), neither branch moved"

# ---------------------------------------------------------------- 2. detached HEAD
#
# A detached HEAD belongs to no branch. It is a mismatch, never "close enough" — and note
# that `git rev-parse --abbrev-ref HEAD` answers the literal string "HEAD" here, which a
# naive string comparison would happily accept as a branch name.

R=$(new_repo detached)
git -C "$R" checkout -q --detach
before_a=$(tip "$R" a); before_b=$(tip "$R" b)
echo more >> "$R/seed.txt"

run detached "$COMMIT" -C "$R" a -- -am "should never land"

[ "$RC" -eq 2 ] || fail detached "expected exit 2, got $RC"
[ "$(tip "$R" a)" = "$before_a" ] || fail detached "branch a moved"
[ "$(tip "$R" b)" = "$before_b" ] || fail detached "branch b moved"
grep -qi detached "$OUT" || fail detached "the refusal must say HEAD is detached"
echo "  ok: detached-head — refused (2), no branch moved"

# ---------------------------------------------------------------- 3. happy path

R=$(new_repo happy)
git -C "$R" checkout -q a
before_a=$(tip "$R" a); before_b=$(tip "$R" b)
echo "task work" >> "$R/seed.txt"

run happy "$COMMIT" -C "$R" a -- -am "feat: legitimate work on the right branch"

[ "$RC" -eq 0 ] || fail happy "a legitimate commit was refused (exit $RC)"
[ "$(tip "$R" a)" != "$before_a" ] || fail happy "branch a did not advance"
[ "$(tip "$R" b)" = "$before_b" ] || fail happy "branch b moved — the commit went to the wrong place"
grep -q "a@$(git -C "$R" rev-parse --short a)" "$OUT" \
  || fail happy "output must report <branch>@<short-sha>"
[ "$(git -C "$R" log -1 --format=%s a)" = "feat: legitimate work on the right branch" ] \
  || fail happy "the commit message did not reach git commit verbatim"
echo "  ok: happy — committed on a, reported a@<sha>, b untouched"

# ---------------------------------------------------------------- 4. HEAD moved mid-commit
#
# The residual race the pre-flight assert cannot close: HEAD moves AFTER the check and BEFORE
# git writes the commit. Simulated deterministically with a pre-commit hook that re-points
# HEAD — the same net effect as the concurrent `git checkout` of the real incident, and the
# same silence: git commit exits 0 with the commit sitting on the wrong branch.
#
# Prevention has already failed by this point; the contract is that detection does not.
#
# The decoy branch `c` is cut from `a`'s own tip on purpose. Re-pointing HEAD at a branch on a
# DIFFERENT commit makes git's ref-lock ("cannot lock ref 'HEAD'") abort the commit, which
# would test git's safety net instead of ours; at an equal tip git commits happily onto
# whichever branch HEAD names at write time — which is precisely the silence under test.

R=$(new_repo head-moved)
git -C "$R" checkout -q a
git -C "$R" branch c a
printf '#!/bin/sh\ngit symbolic-ref HEAD refs/heads/c\n' > "$R/.git/hooks/pre-commit"
chmod +x "$R/.git/hooks/pre-commit"
before_a=$(tip "$R" a); before_c=$(tip "$R" c)
echo "task work" >> "$R/seed.txt"

run head-moved "$COMMIT" -C "$R" a -- -am "feat: work that gets stolen mid-commit"

[ "$RC" -eq 3 ] || fail head-moved "expected exit 3, got $RC"
[ "$(tip "$R" a)" = "$before_a" ] || fail head-moved "branch a moved, but the hook redirected the commit"
[ "$(tip "$R" c)" != "$before_c" ] || fail head-moved "fixture broken: c should carry the stolen commit"
grep -q "c@$(git -C "$R" rev-parse --short c)" "$OUT" \
  || fail head-moved "the alert must name WHERE the commit actually went"
grep -qi 'cherry-pick' "$OUT" || fail head-moved "the alert must state the recovery"
echo "  ok: head-moved — commit landed on c; reported (3) and named it, silence broken"

# ---------------------------------------------------------------- 5. the commit identity
#
# implement-issue commits as `git -c user.email=… -c user.name="…" commit`. Those are options
# to *git*, not to *git commit*: passed after `--` they reach `git commit -c`, which means
# "reuse this commit's message" and which git refuses to combine with -m ("options '-m' and
# '-c' cannot be used together"). So the guard has to carry them itself, before the subcommand.

R=$(new_repo identity)
git -C "$R" checkout -q a
echo work >> "$R/seed.txt"

run identity "$COMMIT" -C "$R" \
  -c user.email=someone@example.com -c user.name="Some One" \
  a -- -am "feat: authored by the project identity"

[ "$RC" -eq 0 ] || fail identity "the commit-identity form was rejected (exit $RC)"
[ "$(git -C "$R" log -1 --format='%an <%ae>' a)" = "Some One <someone@example.com>" ] \
  || fail identity "the -c identity did not reach the commit (author: $(git -C "$R" log -1 --format='%an <%ae>' a))"
[ "$(git -C "$R" log -1 --format='%cn <%ce>' a)" = "Some One <someone@example.com>" ] \
  || fail identity "the -c identity set the author but not the committer"
echo "  ok: identity — -c reaches git, not git commit; author and committer both set"

# ---------------------------------------------------------------- 6. git's own failure

R=$(new_repo commit-fails)
git -C "$R" checkout -q a
before_a=$(tip "$R" a)

run commit-fails "$COMMIT" -C "$R" a -- -am "nothing is staged"

[ "$RC" -ne 0 ] || fail commit-fails "an empty commit reported success"
[ "$RC" -ne 2 ] || fail commit-fails "git's failure was mislabelled as a refusal"
[ "$RC" -ne 3 ] || fail commit-fails "git's failure was mislabelled as a moved HEAD"
[ "$(tip "$R" a)" = "$before_a" ] || fail commit-fails "branch a moved on a failed commit"
echo "  ok: commit-fails — propagated git's own exit code ($RC), branch unchanged"

# ---------------------------------------------------------------- 7. argument hygiene

R=$(new_repo args)
run no-branch "$COMMIT" -C "$R" -- -am x
[ "$RC" -eq 2 ] || fail no-branch "a missing branch name must refuse (2), got $RC"

run no-commit-args "$COMMIT" -C "$R" a
[ "$RC" -eq 2 ] || fail no-commit-args "missing git commit args must refuse (2), got $RC"

run extra-arg "$COMMIT" -C "$R" a b -- -am x
[ "$RC" -eq 2 ] || fail extra-arg "a stray positional must refuse (2), got $RC"

run not-a-repo "$COMMIT" -C "$WORK" a -- -am x
[ "$RC" -eq 2 ] || fail not-a-repo "a non-repo path must refuse (2), got $RC"
echo "  ok: arguments — a malformed invocation never reaches git commit"

# ---------------------------------------------------------------- 8. foreign working directory
#
# The kit is installed as a plugin and invoked from wherever the agent happens to be, so the
# guard must never depend on its own CWD (cf. ci.yml's plugin-install simulation). It takes
# the repo with `git -C` and never `cd`s.

R=$(new_repo foreign)
git -C "$R" checkout -q a
before_a=$(tip "$R" a)
echo work >> "$R/seed.txt"
FOREIGN=$(mktemp -d "$WORK/foreign-cwd.XXXX")

set +e
OUT="$WORK/out.foreign"
( cd "$FOREIGN" && bash "$COMMIT" -C "$R" a -- -am "feat: committed from elsewhere" ) > "$OUT" 2>&1
RC=$?
set -e

[ "$RC" -eq 0 ] || fail foreign "refused when run from another directory (exit $RC)"
[ "$(tip "$R" a)" != "$before_a" ] || fail foreign "branch a did not advance"
echo "  ok: foreign cwd — the guard follows -C, not the ambient directory"

# ================================================================== guarded-push.sh
#
# `git push -u` exiting 0 does not prove the intended content reached the intended branch.
# In the #26 incident it exited 0, printed "branch … set up to track …", and delivered the
# commit into another agent's pull request. So the push is not believed until the remote is
# read back and shown to carry exactly this HEAD.

# ---------------------------------------------------------------- 9. refusal: wrong branch

R=$(new_repo_with_origin push-wrong-branch)
echo work >> "$R/seed.txt"
git -C "$R" commit -q -am "work on a"
git -C "$R" checkout -q b                       # a concurrent agent switches HEAD
before_remote=$(remote_tip push-wrong-branch a)

run push-wrong "$PUSH" -C "$R" a

[ "$RC" -eq 2 ] || fail push-wrong "expected exit 2, got $RC"
[ "$(remote_tip push-wrong-branch a)" = "$before_remote" ] || fail push-wrong "the remote moved on a refused push"
[ -z "$(remote_tip push-wrong-branch b)" ] || fail push-wrong "branch b reached the remote — this IS the bug"
echo "  ok: push-wrong-branch — refused (2), nothing left the machine"

# ---------------------------------------------------------------- 10. push exits 0, remote did not move
#
# The silent mis-push, reproduced without a race: a `remote.origin.push` refspec sends some
# OTHER ref to `a`. git push exits 0 and reports success — and `a` on the remote is not this
# HEAD. Reading the exit code alone would call that a win.

R=$(new_repo_with_origin push-diverged)
echo work >> "$R/seed.txt"
git -C "$R" commit -q -am "work that must reach the remote"
git -C "$R" branch decoy b
git -C "$R" config remote.origin.push refs/heads/decoy:refs/heads/a

run push-diverged "$PUSH" -C "$R" a

[ "$RC" -eq 4 ] || fail push-diverged "expected exit 4, got $RC"
[ "$(remote_tip push-diverged a)" != "$(git -C "$R" rev-parse HEAD)" ] \
  || fail push-diverged "fixture broken: the remote should NOT hold this HEAD"
grep -qi 'remote' "$OUT" || fail push-diverged "the alert must say the remote disagrees"
echo "  ok: push-diverged — push exited 0 but the remote held another commit; caught (4)"

# ---------------------------------------------------------------- 11. a push that pushes nothing
#
# Same class, blunter: `--dry-run` exits 0 having moved nothing at all. An exit code is not
# a delivery receipt.

R=$(new_repo_with_origin push-dry-run)
echo work >> "$R/seed.txt"
git -C "$R" commit -q -am "work that never leaves"
before_remote=$(remote_tip push-dry-run a)

run push-dry-run "$PUSH" -C "$R" a -- --dry-run

[ "$RC" -eq 4 ] || fail push-dry-run "expected exit 4, got $RC"
[ "$(remote_tip push-dry-run a)" = "$before_remote" ] || fail push-dry-run "a dry run moved the remote"
echo "  ok: push-dry-run — exit 0 from git, remote unmoved; caught (4)"

# ---------------------------------------------------------------- 12. happy path

R=$(new_repo_with_origin push-happy)
echo work >> "$R/seed.txt"
git -C "$R" commit -q -am "work that reaches the remote"
head_sha=$(git -C "$R" rev-parse HEAD)

run push-happy "$PUSH" -C "$R" a

[ "$RC" -eq 0 ] || fail push-happy "a legitimate push was rejected (exit $RC)"
[ "$(remote_tip push-happy a)" = "$head_sha" ] || fail push-happy "the remote does not carry HEAD"
grep -q "$(git -C "$R" rev-parse --short HEAD)" "$OUT" || fail push-happy "output must report the sha it verified"
echo "  ok: push-happy — pushed and proved origin/a == HEAD"

# ---------------------------------------------------------------- 13. first push (-u passthrough)
#
# implement-issue's very first push is `git push -u origin <branch>` on a branch with no
# upstream yet, so the guard has to carry those arguments through.

R=$(new_repo_with_origin push-upstream)
git -C "$R" checkout -q -b fresh
echo work >> "$R/seed.txt"
git -C "$R" commit -q -am "work on a brand-new branch"
head_sha=$(git -C "$R" rev-parse HEAD)

run push-upstream "$PUSH" -C "$R" fresh -- -u origin fresh

[ "$RC" -eq 0 ] || fail push-upstream "the first -u push was rejected (exit $RC)"
[ "$(remote_tip push-upstream fresh)" = "$head_sha" ] || fail push-upstream "the remote does not carry HEAD"
echo "  ok: push-upstream — -u origin <branch> passes through and verifies"

# ---------------------------------------------------------------- 14. git's own failure

R=$(new_repo_with_origin push-fails)
echo work >> "$R/seed.txt"
git -C "$R" commit -q -am work

run push-fails "$PUSH" -C "$R" a -- nosuchremote a

[ "$RC" -ne 0 ] || fail push-fails "a failed push reported success"
[ "$RC" -ne 2 ] || fail push-fails "git's failure was mislabelled as a refusal"
[ "$RC" -ne 4 ] || fail push-fails "git's failure was mislabelled as a diverged remote"
echo "  ok: push-fails — propagated git's own exit code ($RC)"

# ---------------------------------------------------------------- 15. detached HEAD + arguments

R=$(new_repo_with_origin push-detached)
git -C "$R" checkout -q --detach
run push-detached "$PUSH" -C "$R" a
[ "$RC" -eq 2 ] || fail push-detached "a detached HEAD must refuse (2), got $RC"
grep -qi detached "$OUT" || fail push-detached "the refusal must say HEAD is detached"

run push-no-branch "$PUSH" -C "$R"
[ "$RC" -eq 2 ] || fail push-no-branch "a missing branch name must refuse (2), got $RC"

run push-not-a-repo "$PUSH" -C "$WORK" a
[ "$RC" -eq 2 ] || fail push-not-a-repo "a non-repo path must refuse (2), got $RC"
echo "  ok: push arguments — detached HEAD and malformed invocations never reach git push"

# ---------------------------------------------------------------- 16. foreign working directory

R=$(new_repo_with_origin push-foreign)
echo work >> "$R/seed.txt"
git -C "$R" commit -q -am "work pushed from elsewhere"
head_sha=$(git -C "$R" rev-parse HEAD)
FOREIGN=$(mktemp -d "$WORK/push-foreign-cwd.XXXX")

set +e
OUT="$WORK/out.push-foreign"
( cd "$FOREIGN" && bash "$PUSH" -C "$R" a ) > "$OUT" 2>&1
RC=$?
set -e

[ "$RC" -eq 0 ] || fail push-foreign "refused when run from another directory (exit $RC)"
[ "$(remote_tip push-foreign a)" = "$head_sha" ] || fail push-foreign "the remote does not carry HEAD"
echo "  ok: push foreign cwd — the guard follows -C, not the ambient directory"

echo "guarded-git golden test OK"
