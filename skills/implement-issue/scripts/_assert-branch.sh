#!/usr/bin/env bash
# _assert-branch.sh — the branch assertion, in one place. SOURCED by the guards, never executed.
#
# Why this file exists (#44). guarded-commit.sh and guarded-push.sh enforce one invariant — HEAD
# must be the branch the caller named — and each carried its own copy of it: refuse(), the usage()
# slice, the is-this-a-repo check, and the whole symbolic-ref pre-flight including its four-line
# comment. Two copies of the security-relevant part of a guard is two things to review and one of
# them to forget. They had already drifted before #30 merged: its /code-review pass found that one
# script validated an option's value and the other did not, so a typo fell through to a bare exit 1
# — the code these scripts document as "git's own failure", which a caller may read as transient and
# retry. This portfolio has been bitten by the shape before: the same IndexError lived in three
# tools in repo-audit, was fixed in one, and stayed live in the other two until someone went looking.
#
# The leading underscore says this is not a command. There is deliberately no `set -euo pipefail`
# here: the callers set it, and re-setting it in a sourced file would mean this file silently
# decides the shell options of every script that loads it.
#
# ---------------------------------------------------------------------------------- the contract
#
#   refuse <tool-name> <message…>
#       Print "<tool-name>: REFUSED — <message>" on stderr and exit 2.
#
#       The tool name is an ARGUMENT and not derived from $0. Deriving it would be free, and would
#       make the message prefix a function of whatever the file happens to be called — while the
#       prefix is a published constant: the golden test matches on it, and so does the
#       troubleshooting table in ../references/github-mechanics.md. A renamed file, a symlink, or a
#       copy must not be able to change it.
#
#   usage
#       Print the caller's own header block, whatever length it happens to be. `$0` stays the
#       SOURCING script inside a sourced file, so one definition documents every guard. Not a
#       hardcoded line range: that silently stops printing before the exit-code table the moment a
#       line is added above it, and --help is exactly what someone reads when they have hit an exit
#       code they do not recognise.
#
#   head_branch_of <repo>
#       Echo the branch HEAD points at, or nothing at all when HEAD is detached. Used by
#       assert_branch below AND by each guard's post-write re-assertion, so the one subtle thing
#       about reading a branch name lives in one function rather than in three places.
#
#   assert_branch <tool-name> <detached-message> <mismatch-message>
#       Reads   $REPO      the worktree to inspect
#               $EXPECTED  the branch the caller says this task owns
#       Sets    $head_sha  HEAD's full sha — the witness for the caller's own post-write comparison
#
#       Those two are read as globals, per this file's contract, so a caller that forgets to set
#       one would die on `set -u`'s "unbound variable" with exit 1 — the ambiguous "git's own
#       failure" code this entire file exists to avoid, produced by the one function whose job is
#       to refuse with 2. They are therefore checked, not assumed.
#       Returns 0 only when HEAD is a branch and that branch is $EXPECTED. Every other outcome —
#       $REPO is not a directory, not a git repository, HEAD is detached, HEAD is another branch —
#       refuses with exit 2 and writes nothing.
#
#       The two messages belong to the CALLER because the consequence genuinely differs per tool:
#       an unguarded commit lands work on the wrong branch and a later push carries it into that
#       branch's pull request, while an unguarded push carries it there itself. Flattening both
#       into one generic sentence would trade the only part of a refusal a reader acts on for a
#       slightly smaller diff. In <mismatch-message> the token `{found}` stands for the branch HEAD
#       is actually on, and may appear as often as the prose needs it.
#
#       That token is substituted as a plain string, NOT through printf. A branch name is data from
#       outside this process, and a `%` in one reaching a format string is a bug waiting for the
#       branch that contains it; positional printf specifiers would also have to be trusted to
#       behave identically on every bash the kit runs under.

# Sourced, not run. Without this, a stray `chmod +x` turns the helper into something that looks
# like a command, asserts nothing, and exits 0 — the most misleading thing a guard-shaped file can
# do. `${BASH_SOURCE[0]:-}` because the callers run under `set -u`.
if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
  printf '_assert-branch.sh: this file is sourced by the guarded-* scripts, not run directly.\n' >&2
  exit 2
fi

refuse() {
  local tool="$1"; shift
  printf '%s: REFUSED — %s\n' "$tool" "$*" >&2
  exit 2
}

usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; }

# `symbolic-ref` and not `rev-parse --abbrev-ref HEAD`: on a detached HEAD the latter prints the
# literal string "HEAD", which compares as a plain branch name and would sail past a naive string
# test. symbolic-ref simply fails, which is the answer we want — so an empty answer here means
# "detached", and every caller reads it that way.
head_branch_of() { git -C "$1" symbolic-ref --quiet --short HEAD 2>/dev/null || true; }

assert_branch() {
  local tool="$1" detached_message="$2" mismatch_message="$3"
  local head_branch

  # The contract's two globals, checked rather than assumed — see the header for why an unbound
  # variable would be the worst possible outcome of a guard's own assertion.
  [ -n "${REPO:-}" ]     || refuse "$tool" "internal: \$REPO is unset — the caller must set it before calling assert_branch."
  [ -n "${EXPECTED:-}" ] || refuse "$tool" "internal: \$EXPECTED is unset — the caller must set it before calling assert_branch."

  [ -d "$REPO" ] || refuse "$tool" "-C path is not a directory: $REPO"

  git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 \
    || refuse "$tool" "not a git repository: $REPO"

  head_branch=$(head_branch_of "$REPO")

  [ -n "$head_branch" ] || refuse "$tool" "$detached_message"

  [ "$head_branch" = "$EXPECTED" ] \
    || refuse "$tool" "${mismatch_message//\{found\}/$head_branch}"

  # Tolerant of failure on purpose: on an unborn branch (freshly `git init`ed, nothing committed)
  # symbolic-ref succeeds while HEAD resolves to no commit, and dying there under the caller's
  # `set -e` would turn a legitimate first commit into an unexplained exit 1. The callers treat an
  # empty $head_sha as "there is no tip yet" — guarded-commit.sh because that is the normal state
  # before a first commit, guarded-push.sh by refusing, because it has nothing to verify.
  #
  # `--verify --quiet` and NOT a bare `rev-parse HEAD 2>/dev/null || true`. That is the same trap
  # this file already documents one function up, in its second costume: on an unborn branch
  # `git rev-parse HEAD` prints the literal string "HEAD" ON STDOUT and exits 128, so `|| true`
  # swallows the status and hands the caller "HEAD" as though it were a sha. Measured, not assumed
  # — and guarded-commit.sh carried exactly that line before this refactor. `--verify --quiet`
  # prints nothing and fails, which is the answer we want. An emptiness test is only a test if the
  # empty case is actually capable of being empty.
  head_sha=$(git -C "$REPO" rev-parse --verify --quiet HEAD 2>/dev/null || true)
}
