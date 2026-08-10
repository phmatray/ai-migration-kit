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

[ -x "$COMMIT" ] || { echo "FAIL: $COMMIT missing or not executable"; exit 1; }

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

tip() { git -C "$1" rev-parse "refs/heads/$2"; }

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

echo "guarded-git golden test OK"
