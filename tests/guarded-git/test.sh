#!/usr/bin/env bash
# Golden test for guarded-commit.sh / guarded-push.sh / guarded-merge.sh — the guarded writes
# that replace
#   git commit -am "..."   /   git push   /   git merge origin/main
# in implement-issue and in the main-sync both lifecycle skills share.
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
MERGE="$KIT/skills/implement-issue/scripts/guarded-merge.sh"

[ -x "$COMMIT" ] || { echo "FAIL: $COMMIT missing or not executable"; exit 1; }
[ -x "$PUSH" ]   || { echo "FAIL: $PUSH missing or not executable"; exit 1; }
[ -x "$MERGE" ]  || { echo "FAIL: $MERGE missing or not executable"; exit 1; }

# Scratch dir and EXIT trap come from the shared preamble (#72) — eight suites each had
# their own, and they had diverged. KIT_ROOT is derived from this file's location rather
# than $PWD: $PWD is only right because a `cd` sits above, and moving it would break the
# source silently (tests/ci-wiring did exactly that).
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$KIT_ROOT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT_ROOT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT_ROOT"
WORK=$(kit_scratch)

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
  # A global `core.hooksPath` (pre-commit, husky, lefthook) makes git ignore $d/.git/hooks, which
  # would silently disarm case 4's pre-commit hook and turn the one case proving exit 3 into an
  # environment-dependent red bar. Pin it, and drop any inherited commit template.
  git -C "$d" config core.hooksPath "$d/.git/hooks"
  git -C "$d" config --unset-all commit.template 2>/dev/null || true
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

# The scratch repo shaped like a real sync: `a` (the task's branch) and `m` (standing in for
# origin/main) both advanced after forking from the seed, so `git merge m` while on `a` is a
# REAL merge — it writes a merge commit instead of fast-forwarding, and that commit is the
# largest single write the lifecycle makes. `b` comes along from new_repo() and plays the
# concurrent agent's branch. Pass "conflict" to make both sides rewrite the same line.
new_merge_repo() {
  local d; d=$(new_repo "$1")
  local mode="${2:-clean}"
  # Clean mode: each side edits a file of its own, so the merge has nothing to reconcile.
  # Conflict mode: both rewrite the SAME file, which is what a real sync hits.
  local a_file=a-only.txt m_file=m-only.txt
  if [ "$mode" = conflict ]; then a_file=shared.txt; m_file=shared.txt; fi

  git -C "$d" checkout -q -b m a          # `m` forks from the seed, where `a` still sits
  echo "m-side" > "$d/$m_file"
  git -C "$d" add -A
  git -C "$d" commit -q -m "m advances (stands in for origin/main)"

  git -C "$d" checkout -q a
  echo "a-side" > "$d/$a_file"
  git -C "$d" add -A
  git -C "$d" commit -q -m "a advances"
  printf '%s' "$d"
}

tip() { git -C "$1" rev-parse "refs/heads/$2"; }

# Non-empty when the index carries conflict entries — the witness for exit 5, read from git's
# index rather than inferred from an exit code that also means half a dozen other things.
unmerged() { git -C "$1" ls-files --unmerged; }

# What the REMOTE actually holds — read from the bare repo itself, so the assertion never
# depends on the local remote-tracking ref the push under test is what updates.
remote_tip() { git -C "$WORK/$1.git" rev-parse --quiet --verify "refs/heads/$2" || true; }

# Installs a pre-push hook running one shell line, so a case can move HEAD — or the branch under
# it — DURING the push, deterministically. Three push cases need that now, and #72's rule is one
# home per shared mechanism rather than a copy per caller.
with_prepush_hook() {
  printf '#!/bin/sh\n%s\n' "$2" > "$1/.git/hooks/pre-push"
  chmod +x "$1/.git/hooks/pre-push"
}

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
# The prefix is a published constant: the troubleshooting table in
# references/github-mechanics.md tells operators to grep for exactly this. Since the refactor it
# is an ARGUMENT passed to a shared refuse() rather than a literal in this script, so it is now
# something that can be got wrong — and until this line, nothing in the suite looked at it.
grep -q '^guarded-commit: REFUSED — ' "$OUT" \
  || fail incident "the refusal must carry the published 'guarded-commit: REFUSED — ' prefix"
grep -q '{found}' "$OUT" \
  && fail incident "the message template leaked a literal {found} instead of the branch name"
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
grep -q "$(git -C "$R" rev-parse --short c)" "$OUT" \
  || fail head-moved "the alert must name the SHA of the commit that was made"
grep -q "branch 'c'" "$OUT" \
  || fail head-moved "the alert must name WHERE the commit actually went"
grep -qi 'cherry-pick' "$OUT" || fail head-moved "the alert must state the recovery"
echo "  ok: head-moved — commit landed on c; reported (3) and named it, silence broken"

# 4b. The same, but HEAD ends up DETACHED. This is the only case where the commit is reachable
# from no ref at all and will be garbage-collected, so it is the one case where the sha is
# load-bearing — and it was the one case the first implementation suppressed it in, because the
# message was built around a branch name that does not exist here.

R=$(new_repo head-detached-mid)
git -C "$R" checkout -q a
printf '#!/bin/sh\ngit checkout -q --detach\n' > "$R/.git/hooks/pre-commit"
chmod +x "$R/.git/hooks/pre-commit"
before_a=$(tip "$R" a)
echo "task work" >> "$R/seed.txt"

run head-detached-mid "$COMMIT" -C "$R" a -- -am "feat: work stranded on a detached HEAD"

[ "$RC" -eq 3 ] || fail head-detached-mid "expected exit 3, got $RC"
[ "$(tip "$R" a)" = "$before_a" ] || fail head-detached-mid "branch a moved unexpectedly"
grep -q "$(git -C "$R" rev-parse --short HEAD)" "$OUT" \
  || fail head-detached-mid "the sha is withheld exactly where nothing else can recover the commit"
grep -qi 'garbage-collected\|DETACHED' "$OUT" \
  || fail head-detached-mid "the alert must say the commit is on a detached HEAD"
echo "  ok: head-detached-mid — sha printed even with no branch to name it"

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

# An option whose value is missing must REFUSE, not fall off `shift 2` into a bare `set -e`
# exit 1 — exit 1 is the documented "git's own failure" bucket, so a typo would be read as a
# git failure and retried.
run dangling-C "$COMMIT" -C
[ "$RC" -eq 2 ] || fail dangling-C "a valueless -C must refuse (2), got $RC"
run dangling-c "$COMMIT" -C "$R" -c
[ "$RC" -eq 2 ] || fail dangling-c "a valueless -c must refuse (2), got $RC"
echo "  ok: arguments — a malformed invocation never reaches git commit"

# ---------------------------------------------------------------- 7b. --help documents the codes
#
# `usage()` prints the header block. It used to be a hardcoded `sed -n '2,42p'`, which silently
# stops before the exit-code table as soon as a line is added above it — and --help is exactly
# what someone reads when they hit a code they do not recognise.

for s in "$COMMIT" "$PUSH" "$MERGE"; do
  run "help-$(basename "$s")" "$s" --help
  [ "$RC" -eq 0 ] || fail "help-$(basename "$s")" "--help exited $RC"
  grep -q 'Usage:' "$OUT" || fail "help-$(basename "$s")" "--help printed no Usage: section"
  for code in '  0 ' '  2 '; do
    grep -q "^$code" "$OUT" || fail "help-$(basename "$s")" "--help omits exit code '$code'"
  done
  grep -q 'Exit codes:' "$OUT" || fail "help-$(basename "$s")" "--help omits the exit-code table"
done
# The code a caller is likeliest to meet and least likely to recognise is the merge guard's 5,
# because it is the only one that means "keep going" — --help has to spell it out.
run help-merge-5 "$MERGE" --help
grep -q '^  5 ' "$OUT" || fail help-merge-5 "--help omits exit code 5, the resolve-then-continue path"
echo "  ok: --help — all three guards print their full header including the exit-code table"

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
# The commit side has asserted its message since the incident case; the push side asserted only
# the exit code, so a typo'd `{found}` token would have shipped a refusal that prints the literal
# token where the operator expects the branch name — the one fact they act on.
grep -q '^guarded-push: REFUSED — ' "$OUT" \
  || fail push-wrong "the refusal must carry the published 'guarded-push: REFUSED — ' prefix"
grep -q "'b'" "$OUT" && grep -q "'a'" "$OUT" \
  || fail push-wrong "the refusal must name both the branch found and the branch expected"
grep -q '{found}' "$OUT" \
  && fail push-wrong "the message template leaked a literal {found} instead of the branch name"
echo "  ok: push-wrong-branch — refused (2), nothing left the machine, message names both branches"

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

# 12b. …the same push, but `ls-remote` writes a line to stderr first.
#
# The read-back used to be captured with `2>&1`, so whatever git or ssh wrote to stderr FIRST
# became line 1 of what the sha parser read (#47). Two entirely ordinary lines do that: the
# known-hosts notice every first SSH connection from a fresh machine, container or CI runner
# prints, and the `warning: redirecting to https://…` of a redirecting HTTPS remote. `awk
# 'NR==1 {print $1}'` then answered with the literal word `Warning:`, which never equals HEAD,
# so the guard printed its "the remote is NOT this HEAD" ALERT and exited 4 — on a push that
# had fully succeeded. SKILL.md tells the agent to read exit 4 as "the work is unpushed", so a
# guard that cries wolf on the success path is worse than no guard at all.
#
# None of the cases above can see it: their origin is a LOCAL bare repo, and `git ls-remote`
# against a path writes nothing to stderr. The test passed for the same reason the bug hid.
# So this case puts a `git` on PATH that does write one — and records that it did, because a
# stub that silently stopped being reached would leave a case that passes while reproducing
# nothing.

R=$(new_repo_with_origin push-noisy-stderr)
echo work >> "$R/seed.txt"
git -C "$R" commit -q -am "work pushed while ls-remote warns"
head_sha=$(git -C "$R" rev-parse HEAD)

STUB="$WORK/noisy-bin"
MARKER="$WORK/noisy-ls-remote-was-called"
mkdir -p "$STUB"
REAL_GIT=$(command -v git)
cat > "$STUB/git" <<EOF
#!/bin/sh
# Noisy for ls-remote only: every other git call the guard makes must behave as usual.
for a in "\$@"; do
  [ "\$a" = ls-remote ] || continue
  echo called >> "$MARKER"
  echo "Warning: Permanently added 'github.com' (ED25519) to the list of known hosts." >&2
  break
done
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$STUB/git"

run push-noisy-stderr env "PATH=$STUB:$PATH" bash "$PUSH" -C "$R" a

[ -s "$MARKER" ] \
  || fail push-noisy-stderr "the stub git was never reached — this case is reproducing nothing"
[ "$RC" -eq 0 ] \
  || fail push-noisy-stderr "a push that succeeded was reported unverified because ls-remote warned on stderr (exit $RC)"
[ "$(remote_tip push-noisy-stderr a)" = "$head_sha" ] \
  || fail push-noisy-stderr "fixture broken: the push itself should have succeeded"
grep -q "$(git -C "$R" rev-parse --short HEAD)" "$OUT" \
  || fail push-noisy-stderr "output must report the sha it verified"
echo "  ok: push-noisy-stderr — a warning on stderr never becomes the sha the guard compares"

# 12c. …and the same again, with the preamble on STDOUT.
#
# The fix for #47 has two independent halves — the streams are split, AND the sha is matched by
# shape instead of by `NR==1` — and 12b alone pins neither: with the split in place no warning
# reaches the parse, so the anchor is never exercised; with the anchor in place the warning is
# skipped even when folded in, so the split is never exercised. Measured on a scratch copy:
# reverting EITHER half left the whole suite green. That is how a later tidy-up deletes the temp
# file and the trap, or restores `NR==1`, with CI applauding.
#
# Splitting the streams cannot help a line git writes on stdout, so this case can only pass if
# the parse is anchored — which is what pins that half. (push-unlistable pins the other half, by
# requiring git's own stderr to reach the ALERT.)

R=$(new_repo_with_origin push-noisy-stdout)
echo work >> "$R/seed.txt"
git -C "$R" commit -q -am "work pushed while ls-remote prefixes stdout"
head_sha=$(git -C "$R" rev-parse HEAD)

STUB_OUT="$WORK/noisy-stdout-bin"
MARKER_OUT="$WORK/noisy-stdout-ls-remote-was-called"
mkdir -p "$STUB_OUT"
cat > "$STUB_OUT/git" <<EOF
#!/bin/sh
for a in "\$@"; do
  [ "\$a" = ls-remote ] || continue
  echo called >> "$MARKER_OUT"
  echo "note: this line is on stdout, ahead of git's answer"
  break
done
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$STUB_OUT/git"

run push-noisy-stdout env "PATH=$STUB_OUT:$PATH" bash "$PUSH" -C "$R" a

[ -s "$MARKER_OUT" ] \
  || fail push-noisy-stdout "the stub git was never reached — this case is reproducing nothing"
[ "$RC" -eq 0 ] \
  || fail push-noisy-stdout "a preamble on stdout was parsed as the remote sha (exit $RC) — the parse is not anchored"
[ "$(remote_tip push-noisy-stdout a)" = "$head_sha" ] \
  || fail push-noisy-stdout "fixture broken: the push itself should have succeeded"
echo "  ok: push-noisy-stdout — the sha is found by shape, not by being on line 1"

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

run push-dangling-C "$PUSH" -C
[ "$RC" -eq 2 ] || fail push-dangling-C "a valueless -C must refuse (2), got $RC"
run push-dangling-remote "$PUSH" -C "$R" --remote
[ "$RC" -eq 2 ] || fail push-dangling-remote "a valueless --remote must refuse (2), got $RC"
echo "  ok: push arguments — detached HEAD and malformed invocations never reach git push"

# ---------------------------------------------------------------- 17. the remote cannot be read
#
# The push succeeds; the read-back does not. Under `set -euo pipefail` a failing `git ls-remote`
# inside a command substitution killed the script on the spot with git's own 128 and no output —
# AFTER a successful push. 128 is the documented "the push failed, nothing else was done" bucket,
# so the caller was told the exact opposite of what happened. Verification that fails is not
# verification that passes: it must be exit 4, and it must say so.

R=$(new_repo_with_origin push-unlistable)
echo work >> "$R/seed.txt"
git -C "$R" commit -q -am "work that really is pushed"
head_sha=$(git -C "$R" rev-parse HEAD)

# Push to the real remote, but verify one that does not exist — the caller-error shape the guard
# must surface rather than die on.
run push-unlistable "$PUSH" -C "$R" a --remote nosuchremote -- origin a

[ "$RC" -eq 4 ] || fail push-unlistable "expected exit 4 on an unreadable remote, got $RC"
[ -s "$OUT" ] || fail push-unlistable "died silently — the caller learns nothing"
grep -qi 'unverified\|could not be listed' "$OUT" \
  || fail push-unlistable "the alert must say the push is UNVERIFIED, not that it failed"
# …and it must carry git's OWN words. Keeping the stderr is the entire reason the read-back does
# not simply discard it, and until this line nothing asserted the message survives: the guard
# could have dropped the capture altogether and stayed green here on the boilerplate above.
grep -q 'does not appear to be a git repository' "$OUT" \
  || fail push-unlistable "git's own stderr must reach the ALERT — that is what the capture is for"
[ "$(remote_tip push-unlistable a)" = "$head_sha" ] \
  || fail push-unlistable "fixture broken: the push itself should have succeeded"
echo "  ok: push-unlistable — push succeeded, read-back failed; reported (4), not a silent 128"

# 17b. …and when the guard cannot capture stderr at all, it must say SO — not report silence.
#
# Keeping git's stderr out of the sha parse (#47) means routing it to a temp file, and a temp file
# is something that can fail to exist: an unwritable TMPDIR, a restrictive container — the same
# fresh-runner environments the known-hosts warning comes from. The first version of this fix fell
# back to /dev/null and then printed "<git ls-remote printed nothing on stderr>", which is a claim
# about git made by a tool that had stopped listening. "It said nothing" and "we discarded what it
# said" are different facts, and only the ALERT can tell an operator which one they are looking at.
#
# `mktemp` is stubbed to fail rather than TMPDIR being pointed at a missing directory: BSD mktemp
# ignores that and succeeds anyway, so the environment trick silently tests nothing (measured).

R=$(new_repo_with_origin push-no-tmpfile)
echo work >> "$R/seed.txt"
git -C "$R" commit -q -am "work that really is pushed"

MK_STUB="$WORK/no-mktemp-bin"
mkdir -p "$MK_STUB"
printf '#!/bin/sh\nexit 1\n' > "$MK_STUB/mktemp"
chmod +x "$MK_STUB/mktemp"

run push-no-tmpfile env "PATH=$MK_STUB:$PATH" bash "$PUSH" -C "$R" a --remote nosuchremote -- origin a

[ "$RC" -eq 4 ] || fail push-no-tmpfile "a failed capture must still be exit 4, got $RC"
grep -qi 'could not be captured' "$OUT" \
  || fail push-no-tmpfile "the ALERT must say the stderr was never captured"
grep -qi 'printed nothing on stderr' "$OUT" \
  && fail push-no-tmpfile "the guard claimed git was silent when it had merely stopped listening"
echo "  ok: push-no-tmpfile — an uncapturable stderr is reported as lost, never as silence"

# ---------------------------------------------------------------- 18. HEAD moved during the push
#
# The asymmetry the review caught: guarded-commit.sh re-asserts after writing, guarded-push.sh
# did not. `git push` sends the CURRENT branch, so a checkout landing between the pre-flight
# assert and the push sends someone else's work — while `ls-remote` still finds the expected
# branch at the tip it already had, which equals the sha captured earlier. Both comparisons pass
# and the guard certifies a push it never made.
#
# Simulated deterministically with a pre-push hook that re-points HEAD, the same technique case 4
# uses for commits.

R=$(new_repo_with_origin push-head-moved)
echo work >> "$R/seed.txt"
git -C "$R" commit -q -am "work on a"
git -C "$R" push -q origin a                     # origin/a already equals HEAD…
git -C "$R" branch decoy a
with_prepush_hook "$R" 'git symbolic-ref HEAD refs/heads/decoy'

run push-head-moved "$PUSH" -C "$R" a

[ "$RC" -eq 4 ] || fail push-head-moved "expected exit 4 when HEAD moved mid-push, got $RC"
grep -qi 'HEAD moved' "$OUT" || fail push-head-moved "the alert must say HEAD moved"
echo "  ok: push-head-moved — re-asserts HEAD after pushing; no certificate for an unmade push"

# ------------------------------------------------- 18b. …and the ALERT must not print a non-sha
#
# The same path as case 18, one line further in. The re-assert reads HEAD's sha for the message,
# and it read it with the spelling assert_branch() in _assert-branch.sh documents as unsafe — in
# the sibling that `.`-loads that very file. The mechanism is written out there and not restated
# here; the short of it is that an unborn HEAD yields the literal string "HEAD", so the ALERT
# rendered `HEAD is now  wip @ HEAD`: a sha the operator can go look up, printed at the exact
# moment they are deciding whether their work reached the remote. There is no such commit.
#
# The VERDICT was never wrong — `head_sha` comes from the safe form, so the comparison still fails
# and the guard still exits 4. A misleading diagnostic and not a wrong exit code is precisely what
# an exit-code assertion cannot see, which is why this case asserts the MESSAGE and why the defect
# survived the refactor that created the shared helper (#92). Case 31's unborn coverage does not
# reach here either: it exercises the PRE-FLIGHT refusal, which fires before the push.

R=$(new_repo_with_origin push-head-unborn)
echo work >> "$R/seed.txt"
git -C "$R" commit -q -am "work on a"
head_sha=$(git -C "$R" rev-parse HEAD)
# Deliberately NOT pre-pushed: the guard's own push is the only thing that can carry this commit
# to the remote, so the `remote_tip` assertion below actually witnesses the push happening rather
# than restating a state the fixture had already arranged. `--orphan` rather than case 18's
# `symbolic-ref` because the point here is an UNREADABLE HEAD, not merely a moved one.
with_prepush_hook "$R" 'git checkout --orphan wip'

run push-head-unborn "$PUSH" -C "$R" a

# The fixture, before the verdict: a `--orphan` that quietly failed would leave HEAD on `a` with a
# perfectly readable sha, the re-assert would agree with itself, and every assertion below would
# pass while testing nothing. An emptiness test is only a test if the empty case can be empty.
[ "$(git -C "$R" symbolic-ref --quiet --short HEAD || true)" = wip ] \
  || fail push-head-unborn "fixture broken: the pre-push hook did not move HEAD to an orphan branch"
[ -z "$(git -C "$R" rev-parse --verify --quiet HEAD || true)" ] \
  || fail push-head-unborn "fixture broken: HEAD is not unborn, so the unsafe read is never exercised"
[ "$(remote_tip push-head-unborn a)" = "$head_sha" ] \
  || fail push-head-unborn "the guard must have pushed before re-asserting — the remote never got the commit"

[ "$RC" -eq 4 ] || fail push-head-unborn "expected exit 4 when HEAD moved mid-push, got $RC"
grep -qi 'HEAD moved' "$OUT" || fail push-head-unborn "the alert must say HEAD moved"

# The sha FIELD of the "HEAD is now" line, and only that field: a fixture that makes HEAD unborn
# also changes the branch, so the line legitimately carries the word HEAD elsewhere (#92).
#
# Two assertions, deliberately, though the second subsumes the first as a condition: they pin two
# different requirements. The first names the REGRESSION, so a reintroduction fails with the words
# an operator would search for; the second pins the prescribed RENDERING, so changing `<unreadable>`
# is a deliberate act rather than a silent one. Collapsing them would keep the coverage and lose
# which of the two broke.
now_line=$(grep 'HEAD is now' "$OUT" || true)
[ -n "$now_line" ] || fail push-head-unborn "the ALERT must name where HEAD ended up"
case "$now_line" in
  *"@ HEAD"*) fail push-head-unborn "the ALERT rendered the literal string HEAD as a sha: $now_line" ;;
esac
case "$now_line" in
  *"@ <unreadable>"*) : ;;
  *) fail push-head-unborn "an unreadable HEAD must be rendered explicitly, got: $now_line" ;;
esac
echo "  ok: push-head-unborn — an unreadable post-push HEAD is reported as such, never as a sha"

# ------------------------------------------- 18c. …and the SHA half of that re-assert is load-bearing
#
# Cases 18 and 18b both move the BRANCH, so `now_branch != EXPECTED` alone satisfies them: delete
# the `|| [ "$now_sha" != "$head_sha" ]` half of the condition and all of them still pass
# (measured — this case exists because that mutation was survivable). The sha half answers a
# different question: HEAD stays on `a` the whole time while `refs/heads/a` is repointed *under*
# it — a concurrent `update-ref`, an `amend`, another worktree committing on the same branch. That
# is the #26 shape with the branch name held constant, and the branch comparison is blind to it.
#
# It matters here specifically because #92 changed how `now_sha` is READ. A test that pins the
# reading but not the comparison would let a later refactor drop the comparison and stay green.

R=$(new_repo_with_origin push-sha-moved)
echo work >> "$R/seed.txt"
git -C "$R" commit -q -am "work on a"
head_sha=$(git -C "$R" rev-parse HEAD)
other_sha=$(tip "$R" b)
# HEAD is left symbolic on `a` throughout — only what `a` POINTS AT changes, so `now_branch` still
# equals the expected branch and the sha comparison is the only thing that can catch this.
with_prepush_hook "$R" "git update-ref refs/heads/a $other_sha"

run push-sha-moved "$PUSH" -C "$R" a

[ "$(git -C "$R" symbolic-ref --quiet --short HEAD || true)" = a ] \
  || fail push-sha-moved "fixture broken: HEAD must stay on a — this case is about the sha alone"
[ "$(git -C "$R" rev-parse HEAD)" = "$other_sha" ] \
  || fail push-sha-moved "fixture broken: the hook did not repoint refs/heads/a under HEAD"

[ "$RC" -eq 4 ] || fail push-sha-moved "expected exit 4 when the branch moved under a steady HEAD, got $RC"
grep -qi 'HEAD moved' "$OUT" || fail push-sha-moved "the alert must say HEAD moved"
grep -q "$head_sha" "$OUT" || fail push-sha-moved "the ALERT must name the sha the push was made from"
echo "  ok: push-sha-moved — the sha half catches a branch repointed under an unmoved HEAD"

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

# ================================================================== guarded-merge.sh
#
# The last unguarded write in the lifecycle (#41). `_shared/sync-with-main.md` ran a bare
# `git merge origin/main` with no branch assertion anywhere, and both lifecycle skills read it.
# A merge commit is the biggest write in the flow, and the window is the widest: conflict
# resolution can take minutes between `git merge` and the commit that completes it.

# ---------------------------------------------------------------- 19. the incident, merged
#
# The #26 shape applied to the merge: the task owns `a`, a concurrent agent checks out `b`,
# and the sync fires. Unguarded, `main` gets merged into somebody else's branch.

R=$(new_merge_repo merge-incident)
git -C "$R" checkout -q b                       # a concurrent agent switches HEAD
before_a=$(tip "$R" a); before_b=$(tip "$R" b); before_m=$(tip "$R" m)

run merge-incident "$MERGE" -C "$R" a -- m

[ "$RC" -eq 2 ] || fail merge-incident "expected exit 2, got $RC"
[ "$(tip "$R" a)" = "$before_a" ] || fail merge-incident "branch a moved"
[ "$(tip "$R" b)" = "$before_b" ] || fail merge-incident "branch b took the merge — this IS the bug"
[ "$(tip "$R" m)" = "$before_m" ] || fail merge-incident "branch m moved"
[ -z "$(unmerged "$R")" ] || fail merge-incident "a refused merge left conflict entries in the index"
[ ! -e "$R/.git/MERGE_HEAD" ] || fail merge-incident "a refused merge left MERGE_HEAD behind"
grep -q "'b'" "$OUT" && grep -q "'a'" "$OUT" \
  || fail merge-incident "the refusal must name both the branch found and the branch expected"
echo "  ok: merge-incident — HEAD switched to b behind the task; refused (2), nothing merged"

# ---------------------------------------------------------------- 20. happy path
#
# A real (non-fast-forward) merge on the branch that asked for it.

R=$(new_merge_repo merge-happy)
before_a=$(tip "$R" a); before_b=$(tip "$R" b)

run merge-happy "$MERGE" -C "$R" a -- m

[ "$RC" -eq 0 ] || fail merge-happy "a legitimate merge was refused (exit $RC)"
[ "$(tip "$R" a)" != "$before_a" ] || fail merge-happy "branch a did not advance"
[ "$(tip "$R" b)" = "$before_b" ] || fail merge-happy "branch b moved — the merge went to the wrong place"
[ "$(git -C "$R" rev-list --parents -1 a | wc -w | tr -d ' ')" = 3 ] \
  || fail merge-happy "fixture broken: this fast-forwarded instead of writing a merge commit"
grep -q "a@$(git -C "$R" rev-parse --short a)" "$OUT" \
  || fail merge-happy "output must report <branch>@<short-sha>"
echo "  ok: merge-happy — merged on a, reported a@<sha>, b untouched"

# ---------------------------------------------------------------- 21. detached HEAD

R=$(new_merge_repo merge-detached)
git -C "$R" checkout -q --detach
before_a=$(tip "$R" a)

run merge-detached "$MERGE" -C "$R" a -- m

[ "$RC" -eq 2 ] || fail merge-detached "expected exit 2, got $RC"
[ "$(tip "$R" a)" = "$before_a" ] || fail merge-detached "branch a moved"
[ ! -e "$R/.git/MERGE_HEAD" ] || fail merge-detached "a refused merge left MERGE_HEAD behind"
grep -qi detached "$OUT" || fail merge-detached "the refusal must say HEAD is detached"
echo "  ok: merge-detached — refused (2), nothing merged"

# ---------------------------------------------------------------- 22. conflicts are exit 5
#
# A conflicted merge is the EXPECTED outcome of a real sync, not a failure — sync-with-main.md
# resolves the conflicts and then completes the merge. Folding it into exit 2 would make
# "refused, nothing written" ambiguous, and folding it into git's propagated 1 would make it
# indistinguishable from half a dozen unrelated refusals. It gets a code of its own, and the
# witness is `git ls-files --unmerged`, not the exit code.

R=$(new_merge_repo merge-conflict conflict)
before_a=$(tip "$R" a)

run merge-conflict "$MERGE" -C "$R" a -- m

[ "$RC" -eq 5 ] || fail merge-conflict "expected exit 5 on conflicts, got $RC"
[ "$(git -C "$R" symbolic-ref --short HEAD)" = a ] \
  || fail merge-conflict "a conflicted merge must leave HEAD on the expected branch"
[ "$(tip "$R" a)" = "$before_a" ] || fail merge-conflict "branch a advanced despite conflicts"
[ -n "$(unmerged "$R")" ] || fail merge-conflict "fixture broken: no conflict entries in the index"
[ -e "$R/.git/MERGE_HEAD" ] || fail merge-conflict "the in-progress merge was not left in place"
grep -q '<<<<<<<' "$R/shared.txt" || fail merge-conflict "no conflict markers in the working tree"
grep -qi 'not a failure' "$OUT" \
  || fail merge-conflict "exit 5 must read as a normal sync outcome, not as an error"
grep -q 'guarded-commit.sh' "$OUT" \
  || fail merge-conflict "the message must name how to COMPLETE the merge after resolving"
grep -q 'shared.txt' "$OUT" \
  || fail merge-conflict "the message must list WHICH files conflicted"
echo "  ok: merge-conflict — exit 5, HEAD still on a, conflicts left to resolve"

# 22b. …and the documented resolve-then-complete path actually works end to end. This runs the
# EXACT staging commands `_shared/sync-with-main.md` prescribes — not a hand-picked `git add
# <file>`, which is what this case used to do while its comment claimed otherwise. A procedure
# nobody executes looks exactly like a procedure that works, so the commands are copied verbatim
# and the fixture below carries every hazard they exist to avoid (#68).

echo resolved > "$R/shared.txt"

run merge-resolved-stage bash -c '
  set -euo pipefail
  git -C "$1" diff --name-only --diff-filter=U -z \
    | git -C "$1" --literal-pathspecs add --pathspec-from-file=- --pathspec-file-nul
' _ "$R"
[ "$RC" -eq 0 ] || fail merge-resolved-stage "the prescribed staging command failed (exit $RC)"

run merge-resolved "$COMMIT" -C "$R" a -- --no-edit

[ "$RC" -eq 0 ] || fail merge-resolved "completing a resolved merge was refused (exit $RC)"
[ "$(tip "$R" a)" != "$before_a" ] || fail merge-resolved "branch a did not advance"
[ "$(git -C "$R" rev-list --parents -1 a | wc -w | tr -d ' ')" = 3 ] \
  || fail merge-resolved "the completed merge is not a merge commit"
[ -z "$(unmerged "$R")" ] || fail merge-resolved "conflict entries survived the completion"
echo "  ok: merge-resolved — the prescribed staging + guarded-commit --no-edit completes the merge"

# 22c. The staging must be NARROW. Three things live in a real worktree at this moment and none
# of them belongs in the merge commit, which lands under an auto-generated "Merge branch …"
# subject no reviewer opens:
#
#   * an unrelated uncommitted edit to a TRACKED file      — swept in by `git add -u`
#   * a tracked file the prescribed build REGENERATED      — swept in by `git add -u`
#   * an untracked build artifact (TestResults/, coverage) — swept in by `git add -A`
#
# …plus a filename that is a valid pathspec GLOB. `app/[id].tsx` is an ordinary dynamic route,
# and passed to `git add` as an argument it wildmatches `app/i.tsx` and stages that instead —
# measured, which is why the prescribed command carries `--literal-pathspecs`.

R=$(new_repo merge-staging-narrow)
git -C "$R" checkout -q a
mkdir -p "$R/app"
echo base > "$R/app/[id].tsx"; echo base > "$R/app/i.tsx"; echo base > "$R/lock.json"
git -C "$R" add -A; git -C "$R" commit -q -m "seed the staging fixture"
git -C "$R" checkout -q -b n a
echo n-side > "$R/app/[id].tsx"; echo n-side > "$R/auto.txt"
git -C "$R" add -A; git -C "$R" commit -q -m "n advances"
git -C "$R" checkout -q a
echo a-side > "$R/app/[id].tsx"
git -C "$R" add -A; git -C "$R" commit -q -m "a advances"

run staging-narrow-merge "$MERGE" -C "$R" a -- n
[ "$RC" -eq 5 ] || fail staging-narrow-merge "fixture broken: expected a conflicted merge, got $RC"

echo resolved     > "$R/app/[id].tsx"     # the resolution
echo unrelated    > "$R/app/i.tsx"        # an unrelated tracked edit (and the glob's victim)
echo regenerated  > "$R/lock.json"        # a tracked file the build rewrote
mkdir -p "$R/TestResults"; echo log > "$R/TestResults/run.log"   # an untracked artifact

run staging-narrow bash -c '
  set -euo pipefail
  git -C "$1" diff --name-only --diff-filter=U -z \
    | git -C "$1" --literal-pathspecs add --pathspec-from-file=- --pathspec-file-nul
' _ "$R"
[ "$RC" -eq 0 ] || fail staging-narrow "the prescribed staging command failed (exit $RC)"

staged=$(git -C "$R" diff --cached --name-only | sort | tr '\n' ' ')
case " $staged " in
  *" app/i.tsx "*)   fail staging-narrow "the glob staged app/i.tsx — --literal-pathspecs is not doing its job" ;;
  *" lock.json "*)   fail staging-narrow "a regenerated tracked file was staged — that is git add -u's bug" ;;
  *"TestResults"*)   fail staging-narrow "an untracked build artifact was staged — that is git add -A's bug" ;;
esac
case " $staged " in
  *" app/[id].tsx "*) : ;;
  *) fail staging-narrow "the resolved path is MISSING from the index: [$staged]" ;;
esac
# git stages what it merged cleanly all by itself, which is why the procedure needs no `add -u`.
case " $staged " in
  *" auto.txt "*) : ;;
  *) fail staging-narrow "fixture broken: git should have staged the auto-merged auto.txt itself" ;;
esac
echo "  ok: staging-narrow — only the resolution + git's own auto-merge; no glob, no -u, no -A"

# ---------------------------------------------------------------- 23. --abort is not a failure
#
# `--abort` walks away from a conflicted merge and exits 0 having moved nothing. A guard that
# insisted the branch advance would call that a failure; this one must not.

R=$(new_merge_repo merge-abort conflict)
before_a=$(tip "$R" a)
run merge-abort-setup "$MERGE" -C "$R" a -- m
[ "$RC" -eq 5 ] || fail merge-abort-setup "fixture broken: expected a conflicted merge, got $RC"

run merge-abort "$MERGE" -C "$R" a -- --abort

[ "$RC" -eq 0 ] || fail merge-abort "--abort was treated as a failure (exit $RC)"
[ "$(tip "$R" a)" = "$before_a" ] || fail merge-abort "--abort moved branch a"
[ ! -e "$R/.git/MERGE_HEAD" ] || fail merge-abort "the merge is still in progress after --abort"
[ -z "$(unmerged "$R")" ] || fail merge-abort "conflict entries survived --abort"
echo "  ok: merge-abort — passes through, exit 0, branch deliberately unmoved"

# 23b. `--continue` passes through too, and needs the `-c` channel for an editor-free run —
# which is the same channel the commit identity travels on.

R=$(new_merge_repo merge-continue conflict)
run merge-continue-setup "$MERGE" -C "$R" a -- m
[ "$RC" -eq 5 ] || fail merge-continue-setup "fixture broken: expected a conflicted merge, got $RC"
before_a=$(tip "$R" a)
echo resolved > "$R/shared.txt"
git -C "$R" add shared.txt

run merge-continue "$MERGE" -C "$R" -c core.editor=true a -- --continue

[ "$RC" -eq 0 ] || fail merge-continue "--continue was rejected (exit $RC)"
[ "$(tip "$R" a)" != "$before_a" ] || fail merge-continue "--continue did not complete the merge"
echo "  ok: merge-continue — passes through and completes the merge on a"

# ---------------------------------------------------------------- 23c. an unmerged index already
#
# `git ls-files --unmerged` is the witness for exit 5, but read only AFTER the merge it cannot tell
# conflicts THIS call created from conflicts that were already sitting there. git itself refuses to
# start a second merge on an unresolved index ("Merging is not possible because you have unmerged
# files", exit 128) — and the guard used to relabel that refusal as "CONFLICTS … a normal sync
# outcome". A caller following the table would then resolve and complete the OLD merge believing the
# freshly fetched base was in the branch. It is not, and the build would be verified against the
# wrong base. So the index is snapshotted BEFORE the merge, and a dirty one refuses.

R=$(new_merge_repo merge-already-conflicted conflict)
run merge-preexisting-setup "$MERGE" -C "$R" a -- m
[ "$RC" -eq 5 ] || fail merge-preexisting-setup "fixture broken: expected a conflicted merge, got $RC"
before_a=$(tip "$R" a)

run merge-preexisting "$MERGE" -C "$R" a -- m

[ "$RC" -eq 2 ] || fail merge-preexisting "a merge onto an already-unmerged index must refuse (2), got $RC"
[ "$(tip "$R" a)" = "$before_a" ] || fail merge-preexisting "branch a moved on a refused merge"
grep -qi 'unresolved\|unmerged' "$OUT" \
  || fail merge-preexisting "the refusal must say the index already carries an unfinished merge"
grep -qi 'normal sync outcome' "$OUT" \
  && fail merge-preexisting "git's 128 was relabelled as a conflict — this IS the bug"
echo "  ok: merge-preexisting — a second merge on an unresolved index refuses (2), not 5"

# 23d. …but the merge-state verbs are exactly what you run WHEN the index is unmerged, so the
# refusal above must not swallow them. `--quit` is the sharp case: it exits 0 having deliberately
# left the index unmerged, which the header lists as a success and the code used to call incomplete.

R=$(new_merge_repo merge-quit conflict)
run merge-quit-setup "$MERGE" -C "$R" a -- m
[ "$RC" -eq 5 ] || fail merge-quit-setup "fixture broken: expected a conflicted merge, got $RC"
before_a=$(tip "$R" a)

run merge-quit "$MERGE" -C "$R" a -- --quit

[ "$RC" -eq 0 ] || fail merge-quit "--quit did exactly what was asked but was reported as $RC"
[ "$(tip "$R" a)" = "$before_a" ] || fail merge-quit "--quit moved branch a"
[ ! -e "$R/.git/MERGE_HEAD" ] || fail merge-quit "fixture broken: --quit should clear MERGE_HEAD"
echo "  ok: merge-quit — a merge-state verb runs on an unmerged index and is a success"

# ---------------------------------------------------------------- 24. no advance is not an error
#
# The two outcomes that separate this guard from guarded-commit.sh: "Already up to date" is the
# single most common result of a real sync, and `--no-commit` stops before writing the commit.
# Both leave the tip exactly where it was, and both are successes.

R=$(new_merge_repo merge-uptodate)
git -C "$R" checkout -q a
before_a=$(tip "$R" a)

run merge-uptodate "$MERGE" -C "$R" a -- a

[ "$RC" -eq 0 ] || fail merge-uptodate "an already-up-to-date merge was reported as a failure ($RC)"
[ "$(tip "$R" a)" = "$before_a" ] || fail merge-uptodate "fixture broken: the branch moved"
grep -q "a@$(git -C "$R" rev-parse --short a)" "$OUT" || fail merge-uptodate "no receipt printed"

R=$(new_merge_repo merge-no-commit)
before_a=$(tip "$R" a)

run merge-no-commit "$MERGE" -C "$R" a -- --no-commit m

[ "$RC" -eq 0 ] || fail merge-no-commit "--no-commit was reported as a failure (exit $RC)"
[ "$(tip "$R" a)" = "$before_a" ] || fail merge-no-commit "--no-commit wrote a commit anyway"
[ -e "$R/.git/MERGE_HEAD" ] || fail merge-no-commit "fixture broken: no merge left in progress"
echo "  ok: no-advance — 'already up to date' and --no-commit are successes, not alarms"

# ---------------------------------------------------------------- 25. HEAD moved mid-merge
#
# The residual race the pre-flight assert cannot close: HEAD moves AFTER the check and BEFORE
# git writes the merge commit. Simulated deterministically with a prepare-commit-msg hook —
# which git runs for a merge — that re-points HEAD, the same technique cases 4 and 18 use.
#
# The decoy branch `c` is cut from `a`'s own tip on purpose: re-pointing HEAD at a branch on a
# DIFFERENT commit makes git's ref-lock abort the write, which would test git's safety net
# instead of ours. At an equal tip git writes the merge commit onto whichever branch HEAD names
# at that moment — precisely the silence under test.
#
# Prevention has already failed by this point; the contract is that detection does not.

R=$(new_merge_repo merge-head-moved)
git -C "$R" branch c a
printf '#!/bin/sh\ngit symbolic-ref HEAD refs/heads/c\n' > "$R/.git/hooks/prepare-commit-msg"
chmod +x "$R/.git/hooks/prepare-commit-msg"
before_a=$(tip "$R" a); before_c=$(tip "$R" c)

run merge-head-moved "$MERGE" -C "$R" a -- m

[ "$RC" -eq 3 ] || fail merge-head-moved "expected exit 3, got $RC"
[ "$(tip "$R" a)" = "$before_a" ] || fail merge-head-moved "branch a moved, but the hook redirected the merge"
[ "$(tip "$R" c)" != "$before_c" ] || fail merge-head-moved "fixture broken: c should carry the stolen merge"
grep -q "branch 'c'" "$OUT" || fail merge-head-moved "the alert must name WHERE the merge went"
grep -q "$(git -C "$R" rev-parse --short c)" "$OUT" \
  || fail merge-head-moved "the alert must name the SHA the merge landed on"
grep -qi 'did NOT advance' "$OUT" || fail merge-head-moved "the alert must say the expected branch is empty-handed"
echo "  ok: merge-head-moved — merge landed on c; reported (3) and named it, silence broken"

# 25b. HEAD moved, but git FAILED — so nothing was written, and the report must say so.
#
# The exit-3 branch is reached by comparing HEAD, which says nothing about whether git wrote
# anything. Reporting "the merge ran … reset that branch to its pre-merge tip" when git had in
# fact refused would send the caller to reset an innocent branch that took nothing — the guard's
# own advice causing the damage it exists to prevent. `pre-merge-commit` runs after the merge is
# carried out and before the commit; failing it aborts the write while the hook has already
# re-pointed HEAD.

R=$(new_merge_repo merge-moved-and-failed)
git -C "$R" branch c a
printf '#!/bin/sh\ngit symbolic-ref HEAD refs/heads/c\nexit 1\n' > "$R/.git/hooks/pre-merge-commit"
chmod +x "$R/.git/hooks/pre-merge-commit"
before_a=$(tip "$R" a); before_c=$(tip "$R" c)

run merge-moved-and-failed "$MERGE" -C "$R" a -- m

[ "$RC" -eq 3 ] || fail merge-moved-and-failed "expected exit 3 when HEAD moved, got $RC"
[ "$(tip "$R" a)" = "$before_a" ] || fail merge-moved-and-failed "branch a moved on a failed merge"
[ "$(tip "$R" c)" = "$before_c" ] || fail merge-moved-and-failed "branch c took a commit git never wrote"
grep -qi 'FAILED' "$OUT" || fail merge-moved-and-failed "the alert must say git failed, not that the merge ran"
grep -qi 'must not be reset\|wrote nothing' "$OUT" \
  || fail merge-moved-and-failed "the alert must NOT prescribe resetting a branch that took nothing"
echo "  ok: merge-moved-and-failed — HEAD moved but git wrote nothing; reported without false recovery advice"

# ---------------------------------------------------------------- 26. git's own failure

R=$(new_merge_repo merge-fails)
before_a=$(tip "$R" a)

run merge-fails "$MERGE" -C "$R" a -- no-such-ref

[ "$RC" -ne 0 ] || fail merge-fails "merging a ref that does not exist reported success"
[ "$RC" -ne 2 ] || fail merge-fails "git's failure was mislabelled as a refusal"
[ "$RC" -ne 3 ] || fail merge-fails "git's failure was mislabelled as a moved HEAD"
[ "$RC" -ne 5 ] || fail merge-fails "git's failure was mislabelled as a conflict"
[ "$(tip "$R" a)" = "$before_a" ] || fail merge-fails "branch a moved on a failed merge"
echo "  ok: merge-fails — propagated git's own exit code ($RC), branch unchanged"

# ---------------------------------------------------------------- 27. the commit identity
#
# git writes the merge commit itself, so the identity has to reach `git`, before the subcommand.

R=$(new_merge_repo merge-identity)

run merge-identity "$MERGE" -C "$R" \
  -c user.email=someone@example.com -c user.name="Some One" \
  a -- m

[ "$RC" -eq 0 ] || fail merge-identity "the commit-identity form was rejected (exit $RC)"
[ "$(git -C "$R" log -1 --format='%an <%ae>' a)" = "Some One <someone@example.com>" ] \
  || fail merge-identity "the -c identity did not reach the merge commit"
[ "$(git -C "$R" log -1 --format='%cn <%ce>' a)" = "Some One <someone@example.com>" ] \
  || fail merge-identity "the -c identity set the author but not the committer"
echo "  ok: merge-identity — -c reaches git, not git merge; the merge commit carries it"

# ---------------------------------------------------------------- 28. argument hygiene

R=$(new_merge_repo merge-args)
run merge-no-branch "$MERGE" -C "$R" -- m
[ "$RC" -eq 2 ] || fail merge-no-branch "a missing branch name must refuse (2), got $RC"

run merge-no-args "$MERGE" -C "$R" a
[ "$RC" -eq 2 ] || fail merge-no-args "missing git merge args must refuse (2), got $RC"

run merge-extra-arg "$MERGE" -C "$R" a b -- m
[ "$RC" -eq 2 ] || fail merge-extra-arg "a stray positional must refuse (2), got $RC"

run merge-not-a-repo "$MERGE" -C "$WORK" a -- m
[ "$RC" -eq 2 ] || fail merge-not-a-repo "a non-repo path must refuse (2), got $RC"

run merge-dangling-C "$MERGE" -C
[ "$RC" -eq 2 ] || fail merge-dangling-C "a valueless -C must refuse (2), got $RC"
run merge-dangling-c "$MERGE" -C "$R" -c
[ "$RC" -eq 2 ] || fail merge-dangling-c "a valueless -c must refuse (2), got $RC"
echo "  ok: merge arguments — a malformed invocation never reaches git merge"

# ---------------------------------------------------------------- 29. foreign working directory

R=$(new_merge_repo merge-foreign)
before_a=$(tip "$R" a)
FOREIGN=$(mktemp -d "$WORK/merge-foreign-cwd.XXXX")

set +e
OUT="$WORK/out.merge-foreign"
( cd "$FOREIGN" && bash "$MERGE" -C "$R" a -- m ) > "$OUT" 2>&1
RC=$?
set -e

[ "$RC" -eq 0 ] || fail merge-foreign "refused when run from another directory (exit $RC)"
[ "$(tip "$R" a)" != "$before_a" ] || fail merge-foreign "branch a did not advance"
echo "  ok: merge foreign cwd — the guard follows -C, not the ambient directory"

# ================================================================== the shared helper
#
# ---------------------------------------------------------------- 30. the helper is missing
#
# The branch assertion has one home, `_assert-branch.sh`, sourced by both guards (#44). That buys a
# single reviewed definition of the invariant and costs a new failure mode: the kit is installed as
# a plugin and its guards are invoked by absolute path, so a partial install — or a guard copied out
# of the kit on its own, which these single-file scripts invite — leaves a guard whose assertion
# cannot load.
#
# A guard that cannot start is a guard that is not guarding, so it must fail CLOSED: refuse (2) and
# name the file it wanted. Letting bash's own "No such file or directory" from the `.` line stand
# would exit 1 — the documented "git's own failure" bucket, which a caller is entitled to read as
# transient and retry.

HELPER="$KIT/skills/implement-issue/scripts/_assert-branch.sh"
[ -r "$HELPER" ] || { echo "FAIL: $HELPER missing or unreadable"; exit 1; }

R=$(new_repo_with_origin helper-missing)
git -C "$R" checkout -q a
before_a=$(tip "$R" a); before_b=$(tip "$R" b)
before_remote=$(remote_tip helper-missing a)
echo "task work" >> "$R/seed.txt"

# A lone guard: copied out with no `_assert-branch.sh` beside it.
LONE=$(mktemp -d "$WORK/lone-guard.XXXX")
cp "$COMMIT" "$PUSH" "$MERGE" "$LONE/"

run helper-missing-commit bash "$LONE/guarded-commit.sh" -C "$R" a -- -am "must never land"

[ "$RC" -eq 2 ] || fail helper-missing-commit "a guard without its helper must refuse (2), got $RC"
grep -q '_assert-branch.sh' "$OUT" \
  || fail helper-missing-commit "the refusal must name the file it could not load"
[ "$(tip "$R" a)" = "$before_a" ] \
  || fail helper-missing-commit "branch a advanced — the commit ran with no assertion behind it"
[ "$(tip "$R" b)" = "$before_b" ] || fail helper-missing-commit "branch b moved"

run helper-missing-push bash "$LONE/guarded-push.sh" -C "$R" a

[ "$RC" -eq 2 ] || fail helper-missing-push "a guard without its helper must refuse (2), got $RC"
grep -q '_assert-branch.sh' "$OUT" \
  || fail helper-missing-push "the refusal must name the file it could not load"
# The suite's contract is "nothing left the machine", not merely "the exit code was 2". Every
# other push case proves that against the bare repo, and a bootstrap that ever degraded to
# refusing AFTER `git push` ran would still satisfy the exit code alone.
[ "$(remote_tip helper-missing a)" = "$before_remote" ] \
  || fail helper-missing-push "the remote moved even though the guard refused"

# --help too. "Never proceeds" has no exception: the helper is loaded before the option loop is
# parsed at all (that loop's own errors are reported through the helper's refuse()), so there is no
# state in which a lone guard does something useful. A --help that worked would advertise a guard
# that cannot guard.
for g in guarded-commit guarded-push guarded-merge; do
  run "helper-missing-help-$g" bash "$LONE/$g.sh" --help
  [ "$RC" -eq 2 ] || fail "helper-missing-help-$g" "--help on a lone guard must refuse (2), got $RC"
  grep -q '_assert-branch.sh' "$OUT" \
    || fail "helper-missing-help-$g" "the refusal must name the file it could not load"
done

# The merge guard joined the helper later than its siblings (#41 landed it self-contained, #44 had
# already extracted the other two), so its bootstrap is the one most likely to be the odd one out.
# It gets the same "refuses, and writes NOTHING" proof rather than only the --help check above.
before_a=$(tip "$R" a); before_b=$(tip "$R" b)
run helper-missing-merge bash "$LONE/guarded-merge.sh" -C "$R" a -- b

[ "$RC" -eq 2 ] || fail helper-missing-merge "a guard without its helper must refuse (2), got $RC"
grep -q '_assert-branch.sh' "$OUT" \
  || fail helper-missing-merge "the refusal must name the file it could not load"
[ "$(tip "$R" a)" = "$before_a" ] \
  || fail helper-missing-merge "branch a advanced — the merge ran with no assertion behind it"
[ "$(tip "$R" b)" = "$before_b" ] || fail helper-missing-merge "branch b moved"
[ ! -e "$R/.git/MERGE_HEAD" ] || fail helper-missing-merge "a refused merge was left in progress"
echo "  ok: helper-missing — a guard that cannot load its assertion refuses (2) and names the file"

# ---------------------------------------------------------------- 30b. the helper is TRUNCATED
#
# The nastier half, and the one a readability check misses: an empty or truncated helper — a
# partial install, an interrupted write, a checkout in flight — is perfectly readable and sources
# without error. It just defines nothing. Testing `-r` would pass it, and the first call would
# then die with bash's `command not found`, exit 127: a code in NO exit-code table, which lands in
# the documented "git's own exit code" bucket and reads as a transient git failure worth retrying.
# So the guard must test that the assertion is CALLABLE, not that the file is present.

for payload in '' '# a comment and nothing else' 'assert_branch_typo() { :; }'; do
  TRUNC=$(mktemp -d "$WORK/trunc-guard.XXXX")
  cp "$COMMIT" "$PUSH" "$MERGE" "$TRUNC/"
  printf '%s' "$payload" > "$TRUNC/_assert-branch.sh"

  before_a=$(tip "$R" a)
  run trunc-commit bash "$TRUNC/guarded-commit.sh" -C "$R" a -- -am "must never land"
  [ "$RC" -eq 2 ] \
    || fail trunc-commit "a helper that defines nothing must refuse (2), got $RC (127 = the hole)"
  grep -q '_assert-branch.sh' "$OUT" || fail trunc-commit "the refusal must name the helper"
  [ "$(tip "$R" a)" = "$before_a" ] || fail trunc-commit "branch a advanced with no assertion loaded"

  run trunc-push bash "$TRUNC/guarded-push.sh" -C "$R" a
  [ "$RC" -eq 2 ] \
    || fail trunc-push "a helper that defines nothing must refuse (2), got $RC (127 = the hole)"
  [ "$(remote_tip helper-missing a)" = "$before_remote" ] \
    || fail trunc-push "the remote moved even though the guard refused"

  before_b=$(tip "$R" b)
  run trunc-merge bash "$TRUNC/guarded-merge.sh" -C "$R" a -- b
  [ "$RC" -eq 2 ] \
    || fail trunc-merge "a helper that defines nothing must refuse (2), got $RC (127 = the hole)"
  [ "$(tip "$R" a)" = "$before_a" ] || fail trunc-merge "branch a took a merge with no assertion loaded"
  [ "$(tip "$R" b)" = "$before_b" ] || fail trunc-merge "branch b moved"
done
echo "  ok: helper-truncated — a readable helper that defines nothing still refuses (2), never 127"

# ---------------------------------------------------------------- 30c. reached through a symlink
#
# Before the helper existed the guards were self-contained, so installing one as a symlink on
# $PATH worked. `dirname "$0"` yields the LINK's directory and `pwd -P` canonicalizes only that
# directory — never the script link itself — so resolving the helper beside `$0` alone would have
# broken every symlink install. The guards resolve $0 through its symlinks first; this proves it.

R=$(new_repo symlinked)
git -C "$R" checkout -q a
before_a=$(tip "$R" a)
echo "task work" >> "$R/seed.txt"
LINKDIR=$(mktemp -d "$WORK/symlink-bin.XXXX")
ln -s "$COMMIT" "$LINKDIR/guarded-commit.sh"
ln -s "$PUSH" "$LINKDIR/gp"          # also renamed, to prove the resolution is not name-based
ln -s "$MERGE" "$LINKDIR/gm"

run symlink-commit bash "$LINKDIR/guarded-commit.sh" -C "$R" a -- -am "feat: committed via a symlink"

[ "$RC" -eq 0 ] || fail symlink-commit "a guard reached through a symlink could not find its helper (exit $RC)"
[ "$(tip "$R" a)" != "$before_a" ] || fail symlink-commit "branch a did not advance"

run symlink-help bash "$LINKDIR/gp" --help
[ "$RC" -eq 0 ] || fail symlink-help "a renamed symlink to guarded-push.sh failed to load (exit $RC)"
grep -q 'Exit codes:' "$OUT" || fail symlink-help "--help through a symlink lost the exit-code table"

run symlink-help-merge bash "$LINKDIR/gm" --help
[ "$RC" -eq 0 ] || fail symlink-help-merge "a renamed symlink to guarded-merge.sh failed to load (exit $RC)"
grep -q '^  5 ' "$OUT" \
  || fail symlink-help-merge "--help through a symlink lost the merge guard's exit-5 row"
echo "  ok: symlinked guard — \$0 is resolved through its links, so the helper is found beside the real file"

# ---------------------------------------------------------------- 30d. the helper is not a command
#
# `_assert-branch.sh` is sourced, never executed. Its leading underscore says so and its file mode
# should too — but prose is not a check, and the suite already machine-checks the inverse property
# (`-x`) for the two guards. A packaging step that blanket-chmods `skills/**/scripts/*.sh`, plus a
# regression in the ${BASH_SOURCE[0]} test, would leave a file that looks like a command and
# asserts nothing — which its own comment calls the most misleading thing a guard-shaped file can be.

[ ! -x "$HELPER" ] || fail helper-mode "_assert-branch.sh is executable — it is sourced, not run"

run helper-run-directly bash "$HELPER"
[ "$RC" -eq 2 ] || fail helper-run-directly "running the helper directly must refuse (2), got $RC"
grep -qi 'sourced' "$OUT" || fail helper-run-directly "the refusal must say the file is meant to be sourced"
echo "  ok: helper-not-a-command — non-executable, and refuses (2) if run directly anyway"

# ---------------------------------------------------------------- 31. an unborn branch
#
# Sharing one assertion must not quietly relax either caller's preconditions, and it nearly did.
# The helper reads HEAD's sha tolerantly because a COMMIT legitimately has none: an unborn branch
# is where a first commit starts. A PUSH has no such case — with no sha there is nothing to prove
# reached the remote, which is this guard's whole promise — so guarded-push.sh must refuse BEFORE
# the write rather than discover the missing witness afterwards.

UNBORN="$WORK/unborn"
git init -q "$UNBORN"
git -C "$UNBORN" symbolic-ref HEAD refs/heads/a
git -C "$UNBORN" config user.email test@example.com
git -C "$UNBORN" config user.name "Guarded Git Test"
git -C "$UNBORN" config commit.gpgsign false
git -C "$UNBORN" config core.hooksPath "$UNBORN/.git/hooks"
git init -q --bare "$WORK/unborn.git"
git -C "$UNBORN" remote add origin "$WORK/unborn.git"

run unborn-push "$PUSH" -C "$UNBORN" a
[ "$RC" -eq 2 ] || fail unborn-push "pushing an unborn branch must refuse (2) before the write, got $RC"
grep -qi 'unborn\|no commit' "$OUT" || fail unborn-push "the refusal must say why there is nothing to push"
[ -z "$(git -C "$WORK/unborn.git" rev-parse --quiet --verify refs/heads/a || true)" ] \
  || fail unborn-push "something reached the remote from an unborn branch"

# The commit side must still work: this is the legitimate first commit.
echo first > "$UNBORN/f.txt"
git -C "$UNBORN" add f.txt
run unborn-commit "$COMMIT" -C "$UNBORN" a -- -m "feat: the very first commit"
[ "$RC" -eq 0 ] || fail unborn-commit "the first commit on an unborn branch was refused (exit $RC)"
[ -n "$(git -C "$UNBORN" rev-parse --quiet --verify refs/heads/a || true)" ] \
  || fail unborn-commit "branch a was not created by the first commit"
echo "  ok: unborn branch — push refuses (2) with no witness; the first commit still lands"

# 31b. …and the MERGE side is a third answer again: it must SUCCEED.
#
# This case is green the day it is written, and that is its job. #78 proposed making guarded-merge
# refuse on an empty $head_sha "as guarded-push.sh does", by analogy rather than by measurement.
# The measurement says otherwise: `git merge <ref>` into an unborn branch is a supported
# fast-forward — it creates the branch at the merged tip and checks the files out — and
# guarded-merge.sh has always allowed it. It is the first sync of a freshly branched worktree.
#
# So the three guards genuinely differ on an unborn HEAD (push refuses, commit and merge proceed),
# and only a test says which is which. Without this case, adopting the shared assertion is one
# plausible-looking `[ -n "$head_sha" ] || refuse` away from silently breaking a working operation.

MUNBORN="$WORK/unborn-merge"
git init -q "$MUNBORN"
git -C "$MUNBORN" config user.email test@example.com
git -C "$MUNBORN" config user.name "Guarded Git Test"
git -C "$MUNBORN" config commit.gpgsign false
git -C "$MUNBORN" config core.hooksPath "$MUNBORN/.git/hooks"
git -C "$MUNBORN" checkout -q -b m
echo m > "$MUNBORN/m.txt"
git -C "$MUNBORN" add m.txt
git -C "$MUNBORN" commit -q -m "m has content"
git -C "$MUNBORN" symbolic-ref HEAD refs/heads/a      # `a` is unborn: refs/heads/a does not exist
git -C "$MUNBORN" read-tree --empty
rm -f "$MUNBORN/m.txt"

[ -z "$(git -C "$MUNBORN" rev-parse --quiet --verify refs/heads/a || true)" ] \
  || fail unborn-merge "fixture broken: branch a should not exist yet"

run unborn-merge "$MERGE" -C "$MUNBORN" a -- m

[ "$RC" -eq 0 ] || fail unborn-merge "merging into an unborn branch must succeed, got $RC"
[ "$(git -C "$MUNBORN" rev-parse --quiet --verify refs/heads/a || true)" = "$(tip "$MUNBORN" m)" ] \
  || fail unborn-merge "branch a was not created at m's tip by the merge"
[ -f "$MUNBORN/m.txt" ] || fail unborn-merge "the merged content was not checked out"
grep -q "^guarded-merge: a@" "$OUT" || fail unborn-merge "the receipt must name the branch and its new tip"
echo "  ok: unborn merge — the first sync into a fresh branch still lands (0), not refused"

# ------------------------------------------- 32. the SUCCESS RECEIPT, with an unreadable HEAD
#
# The receipt is the strongest claim a guard makes — the sentence a caller is asked to believe
# INSTEAD of git's exit code. It was built by interpolating a bare `$(git … rev-parse --short
# HEAD)` straight into a `printf` argument, and a command substitution that FAILS there is
# neither aborted by `set -e` nor reflected in the statement's status. Measured on main at
# 02bbfb6, under the `set -euo pipefail` every guard sets:
#
#     $ printf 'receipt: %s@%s\n' "a" "$(git -C /nonexistent rev-parse --short HEAD 2>/dev/null)"
#     receipt: a@
#     $ echo $?
#     0
#
# So `guarded-commit: a@` — a receipt with the amount left blank, and a zero exit saying it is
# fine. #116 removed exactly this from guarded-push.sh's receipt; its two siblings were outside
# that issue's Area and kept it (#129).
#
# Nothing caught it because no case had ever reached a guard's SUCCESS path with an unreadable
# HEAD: case 31's unborn coverage sits on the REFUSAL paths, which return long before any
# receipt is printed. That gap is what this case closes, for both guards that print one.
#
# The fixture, and why it is shaped this way: a `post-commit` hook runs
# `git update-ref -d refs/heads/a`. HEAD stays SYMBOLIC on `a`, so the post-write re-assert
# agrees and the guard walks all the way to its receipt; `a` no longer exists, so HEAD is
# UNBORN and `rev-parse --short HEAD` exits 128 with nothing on stdout (measured — and the
# reason the abbreviating form is the one used here: the BARE form prints the literal string
# "HEAD" instead, which is #92's separate trap).

R=$(new_repo receipt-unreadable)
git -C "$R" checkout -q a
printf '#!/bin/sh\ngit update-ref -d refs/heads/a\n' > "$R/.git/hooks/post-commit"
chmod +x "$R/.git/hooks/post-commit"
echo "task work" >> "$R/seed.txt"

run receipt-unreadable "$COMMIT" -C "$R" a -- -am "feat: work whose receipt cannot name it"

# The fixture, before the verdict: a hook that quietly did nothing would leave `a` readable, the
# receipt would render a real sha, and every assertion below would pass while testing nothing.
[ "$(git -C "$R" symbolic-ref --quiet --short HEAD || true)" = a ] \
  || fail receipt-unreadable "fixture broken: HEAD must still be symbolic on a, or the re-assert diverts the guard before its receipt"
[ -z "$(git -C "$R" rev-parse --quiet --verify refs/heads/a || true)" ] \
  || fail receipt-unreadable "fixture broken: refs/heads/a survived, so HEAD is readable and the blank is never exercised"

[ "$RC" -eq 0 ] || fail receipt-unreadable "the commit was made and the re-assert passed, so this is the SUCCESS path — got $RC"
receipt=$(grep '^guarded-commit: ' "$OUT" || true)
[ -n "$receipt" ] || fail receipt-unreadable "the guard printed no receipt at all"
# Two assertions on purpose, as at case 18b: the first names the REGRESSION in the words an
# operator would search for, the second pins the prescribed RENDERING so changing `<unreadable>`
# is a deliberate act. Collapsing them keeps the coverage and loses which of the two broke.
case "$receipt" in
  *@) fail receipt-unreadable "the receipt names no commit: $receipt" ;;
esac
case "$receipt" in
  *"a@<unreadable>"*) : ;;
  *) fail receipt-unreadable "an unreadable HEAD must be rendered explicitly in the receipt, got: $receipt" ;;
esac
echo "  ok: receipt-unreadable — guarded-commit's success receipt never leaves the sha field blank"

# 32b. …and the same for guarded-merge.sh's receipt, which carries the identical defect.
#
# `post-merge` and not `post-commit`: measured, `git merge` does not run the post-commit hook for
# the merge commit it writes, so the sibling fixture would silently no-op — leaving `a` readable
# and this case green for the wrong reason.

R=$(new_merge_repo receipt-unreadable-merge)
printf '#!/bin/sh\ngit update-ref -d refs/heads/a\n' > "$R/.git/hooks/post-merge"
chmod +x "$R/.git/hooks/post-merge"

run receipt-unreadable-merge "$MERGE" -C "$R" a -- m

[ "$(git -C "$R" symbolic-ref --quiet --short HEAD || true)" = a ] \
  || fail receipt-unreadable-merge "fixture broken: HEAD must still be symbolic on a"
[ -z "$(git -C "$R" rev-parse --quiet --verify refs/heads/a || true)" ] \
  || fail receipt-unreadable-merge "fixture broken: refs/heads/a survived, so the post-merge hook never ran"

[ "$RC" -eq 0 ] || fail receipt-unreadable-merge "the merge succeeded and HEAD never left a, so this is the SUCCESS path — got $RC"
receipt=$(grep '^guarded-merge: ' "$OUT" || true)
[ -n "$receipt" ] || fail receipt-unreadable-merge "the guard printed no receipt at all"
case "$receipt" in
  *@) fail receipt-unreadable-merge "the receipt names no commit: $receipt" ;;
esac
case "$receipt" in
  *"a@<unreadable>"*) : ;;
  *) fail receipt-unreadable-merge "an unreadable HEAD must be rendered explicitly in the receipt, got: $receipt" ;;
esac
echo "  ok: receipt-unreadable-merge — guarded-merge's success receipt never leaves the sha field blank"

# ---------------------------------------------------------------- 33. ONE spelling for the read
#
# The two cases above pin the OUTPUT. This one pins the reason the output was wrong, because the
# blank receipt was never really a typo: reading HEAD's branch had a home (head_branch_of, #44)
# and reading HEAD's SHA had none, so every message that wanted one respelled the read. Four
# spellings across four files, and the fourth — a bare `$(git … rev-parse …)` interpolated into a
# printf argument — is the defect. That there were four at all is why a fifth is cheap to add,
# which is what this case makes expensive.
#
# It is a STATIC scan on purpose. A behavioural case can only reach a spelling that some fixture
# happens to exercise; the whole lesson of #44/#72/#78/#92/#129 is that the copy nobody exercises
# is the one that keeps the bug. So the assertion is over the source itself.
#
# Whole-line comments are excluded, and have to be: these guards carry long prose headers that
# QUOTE the very spellings under test — that is what the headers are for — and a scan that read
# them would be permanently red with no way to fix it that did not delete the reasoning.
guard_code() {
  awk -v f="$(basename "$1")" '!/^[[:space:]]*#/ { print f ":" NR ": " $0 }' "$1"
}

# 33a. The ABBREVIATING read — `rev-parse … --short` — has exactly one home, and it is the
# helper. This is the read-kind that carried the defect, in three of its four spellings.
spellings=""
for g in "$COMMIT" "$PUSH" "$MERGE"; do
  hits=$(guard_code "$g" | grep -E 'rev-parse.*--short' || true)
  [ -z "$hits" ] || spellings="$spellings$hits
"
done
if [ -n "$spellings" ]; then
  OUT="$WORK/out.one-spelling"
  printf '%s' "$spellings" > "$OUT"
  fail one-spelling "abbreviating a sha belongs to head_sha_of in _assert-branch.sh; these guards still spell it themselves:"
fi

helper_homes=$(guard_code "$HELPER" | grep -cE 'rev-parse.*--short' || true)
OUT=""
[ "$helper_homes" -eq 1 ] || fail one-spelling-home \
  "the abbreviating read must have exactly ONE home in _assert-branch.sh, found $helper_homes"

# 33b. …and no message may build one inline. This is the shape of the bug rather than one of its
# instances: a command substitution that fails inside a `printf`/`echo` argument is neither
# aborted by `set -e` nor reflected in the statement's status, so the field renders empty and the
# guard exits 0 having named no commit. Reading into a variable first is what makes the failure
# observable, which is why the rule is about WHERE the substitution sits, not about which flags
# it carries.
inlined=""
for g in "$COMMIT" "$PUSH" "$MERGE" "$HELPER"; do
  hits=$(guard_code "$g" | grep -E '(printf|echo).*\$\(git' || true)
  [ -z "$hits" ] || inlined="$inlined$hits
"
done
if [ -n "$inlined" ]; then
  OUT="$WORK/out.inlined-substitution"
  printf '%s' "$inlined" > "$OUT"
  fail inlined-substitution "a git read inside a printf/echo argument fails invisibly — read it into a variable first:"
fi

# 33c. …and the FULL-sha witness read keeps its safe spelling. Different read-kind, same file,
# and green the day it is written — which is its job, exactly as case 31b's is. `rev-parse HEAD`
# with no `--verify` prints the literal string "HEAD" on an unborn branch and exits 128, so
# `|| true` hands the caller "HEAD" as though it were a sha; that is #92, and it is one careless
# edit away from coming back in a file that now invites people to touch its sha reads.
unsafe=""
for g in "$COMMIT" "$PUSH" "$MERGE" "$HELPER"; do
  hits=$(guard_code "$g" | grep -E 'rev-parse[[:space:]]+HEAD' || true)
  [ -z "$hits" ] || unsafe="$unsafe$hits
"
done
if [ -n "$unsafe" ]; then
  OUT="$WORK/out.unsafe-head-read"
  printf '%s' "$unsafe" > "$OUT"
  fail unsafe-head-read "a bare 'rev-parse HEAD' answers with the literal string HEAD on an unborn branch (#92) — use --verify --quiet:"
fi
OUT=""
echo "  ok: one-spelling — the sha read has one home, no message builds one inline, and #92's spelling stays out"

# ---------------------------------------------------------------- 34. `detached` is a MEASUREMENT
#
# head_branch_of() answers with nothing in TWO situations — HEAD is genuinely detached, and the
# repo cannot be read at all — and every post-write re-assert rendered `${now_branch:-detached}`,
# which turns the second into a definite claim about the first.
#
# In assert_branch's PRE-FLIGHT that conflation is harmless, and deliberately so: it has proven
# the path is a git repository two lines earlier, so empty there really does mean detached. After
# the write nothing has proven any such thing — and "the worktree is gone" is precisely the
# concurrency class these guards exist for (#129, the same "cannot tell nothing from failed"
# shape as #124).
#
# What it cost, measured before the fix: the commit below lands safely on `a`, HEAD never leaves
# `a`, and the guard tells the operator HEAD is detached, that the commit "is reachable from
# nothing and will be garbage-collected", and hands them a rescue command ending in
# `<unreadable>`. Every word of that is false, and it is the sentence they act on.
#
# The fixture points the guard at a SYMLINK and has the hook remove it. git resolves its
# directories once, at startup, so the write itself completes untouched while every later
# `git -C <link>` the guard makes fails — the shape of a worktree pruned or moved under a running
# command. Nothing is destroyed, which is what lets each case also assert where the work really
# went, and so prove the old message was wrong rather than merely differently worded.

R=$(new_repo unreadable-commit)
git -C "$R" checkout -q a
LINK="$WORK/unreadable-commit-link"
ln -s "$R" "$LINK"
printf '#!/bin/sh\nrm -f %s\n' "$LINK" > "$R/.git/hooks/post-commit"
chmod +x "$R/.git/hooks/post-commit"
before_a=$(tip "$R" a)
echo "task work" >> "$R/seed.txt"

run unreadable-commit "$COMMIT" -C "$LINK" a -- -am "feat: work whose worktree is pruned under it"

[ ! -e "$LINK" ] || fail unreadable-commit "fixture broken: the hook left the symlink in place, so the repo is still readable"
[ "$(tip "$R" a)" != "$before_a" ] || fail unreadable-commit "fixture broken: the commit never landed, so there is nothing to mis-describe"
[ "$(git -C "$R" symbolic-ref --quiet --short HEAD || true)" = a ] \
  || fail unreadable-commit "fixture broken: HEAD really did leave a — this case must be about the PATH, not about HEAD"

[ "$RC" -eq 3 ] || fail unreadable-commit "expected exit 3 when the repo cannot be re-read, got $RC"
grep -qi 'detached' "$OUT" \
  && fail unreadable-commit "the ALERT claims HEAD is detached — HEAD is on 'a' and the commit is safely there; the PATH is what vanished"
grep -qi 'cannot be read\|could not be read\|no longer be read' "$OUT" \
  || fail unreadable-commit "the ALERT must say the repository could not be read"
grep -q "HEAD is now '<unreadable>'" "$OUT" \
  || fail unreadable-commit "the branch field must render <unreadable>, not a state nothing measured"
echo "  ok: unreadable-commit — a vanished worktree is reported as unreadable, never as detached"

# 34b. …the same for guarded-merge.sh's post-write re-assert.

R=$(new_merge_repo unreadable-merge)
LINK="$WORK/unreadable-merge-link"
ln -s "$R" "$LINK"
printf '#!/bin/sh\nrm -f %s\n' "$LINK" > "$R/.git/hooks/post-merge"
chmod +x "$R/.git/hooks/post-merge"
before_a=$(tip "$R" a)

run unreadable-merge "$MERGE" -C "$LINK" a -- m

[ ! -e "$LINK" ] || fail unreadable-merge "fixture broken: the hook left the symlink in place"
[ "$(tip "$R" a)" != "$before_a" ] || fail unreadable-merge "fixture broken: the merge never landed"
[ "$(git -C "$R" symbolic-ref --quiet --short HEAD || true)" = a ] \
  || fail unreadable-merge "fixture broken: HEAD really did leave a"

[ "$RC" -eq 3 ] || fail unreadable-merge "expected exit 3 when the repo cannot be re-read, got $RC"
grep -qi 'detached' "$OUT" \
  && fail unreadable-merge "the ALERT claims HEAD is detached for a repo whose PATH is simply gone"
grep -qi 'cannot be read\|could not be read\|no longer be read' "$OUT" \
  || fail unreadable-merge "the ALERT must say the repository could not be read"
grep -q "HEAD is now '<unreadable>'" "$OUT" \
  || fail unreadable-merge "the branch field must render <unreadable>, not a state nothing measured"
echo "  ok: unreadable-merge — a vanished worktree is reported as unreadable, never as detached"

# 34c. …and guarded-push.sh, whose re-assert renders the same two fields side by side. Its sha
# half already said `<unreadable>` (#92 fixed that one); the branch half beside it still said
# `detached`, so the line read `HEAD is now  detached @ <unreadable>` — one measured field and
# one invented, in the same sentence.

R=$(new_repo_with_origin unreadable-push)
echo work >> "$R/seed.txt"
git -C "$R" commit -q -am "work on a"
LINK="$WORK/unreadable-push-link"
ln -s "$R" "$LINK"
with_prepush_hook "$R" "rm -f $LINK"

run unreadable-push "$PUSH" -C "$LINK" a

[ ! -e "$LINK" ] || fail unreadable-push "fixture broken: the hook left the symlink in place"
[ "$(remote_tip unreadable-push a)" = "$(tip "$R" a)" ] \
  || fail unreadable-push "fixture broken: the push never reached the remote, so the re-assert is not what is under test"
[ "$(git -C "$R" symbolic-ref --quiet --short HEAD || true)" = a ] \
  || fail unreadable-push "fixture broken: HEAD really did leave a"

[ "$RC" -eq 4 ] || fail unreadable-push "expected exit 4 when the repo cannot be re-read, got $RC"
grep -qi 'detached' "$OUT" \
  && fail unreadable-push "the ALERT claims HEAD is detached for a repo whose PATH is simply gone"
grep -q '<unreadable> @' "$OUT" \
  || fail unreadable-push "the branch field must render <unreadable> beside the sha field, not a state nothing measured"
echo "  ok: unreadable-push — a vanished worktree is reported as unreadable, never as detached"

echo "guarded-git golden test OK"
