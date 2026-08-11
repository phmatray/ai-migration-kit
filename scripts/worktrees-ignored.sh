#!/usr/bin/env bash
# worktrees-ignored.sh — assert that an agent worktree can never be committed to this repository.
#
# Why this exists (#43). The harness puts agent worktrees under `.claude/worktrees/`. Unignored,
# any `git add -A` in this repository stages one, so the guarantee has to be mechanical rather
# than remembered.
#
# ⚠️ The original trigger — `skills/_shared/sync-with-main.md` finishing a merge with `git add -A`,
# on the common path of both lifecycle skills — is GONE as of #68: that procedure now stages only
# the conflicted paths, and no skill in this kit runs `add -A` any more. This gate is therefore no
# longer defending against the kit's own command, and the rest of this header should be read that
# way. It still earns its place, for two reasons that outlive the command that prompted it:
#
#   * a human (or another agent) typing `git add -A` in the main checkout is not governed by
#     anything the kit does, and this repo is where the agents run; and
#   * the ignore rule is cheap and the failure is silent and irreversible-ish, which is exactly the
#     trade this gate exists to take.
#
# Do not read the removal as a reason to delete the rule — read it as the reason this header no
# longer names a caller.
#
# WHAT IT ACTUALLY STAGES, measured (git 2.50.1) rather than assumed, because the intuitive answer
# is wrong and sends you looking for the wrong symptom: a linked worktree carries a `.git` FILE,
# so `git add -A` records ONE gitlink —
#     160000 <sha> 0  .claude/worktrees/<branch>
# — not a copy of the tree. Whoever debugs this is not hunting an enormous diff; they are hunting
# a single submodule-shaped entry pointing at a commit no clone can fetch, since there is no
# submodule URL and no remote. git prints "warning: adding embedded git repository", and that
# warning on a busy console is the only thing standing between this and a silent commit.
#
# TWO worktree homes are checked, because two are reachable:
#   .claude/worktrees/  what this harness creates, and what merge-pr hardcodes.
#   .worktrees/         what superpowers:using-git-worktrees falls back to (its Step 1b) when no
#                       native worktree tool exists. implement-issue Step 4 delegates worktree
#                       creation to that skill, so a contributor on a bare harness lands there
#                       instead — and a rule naming only `.claude/` would pass while that
#                       contributor's `git add -A` staged `.worktrees/<branch>`. Measured: it does.
#
# ONE path must stay VISIBLE: `.claude/skills/repo-profile.md`. get-repo-profile writes it and
# tells consumer repos to commit it, so broadening this rule to all of `.claude/` would make this
# repo — the reference implementation people copy — silently contradict the contract it documents.
# Nothing else catches that: the CI step asserting this repo has no profile tests the file's
# ABSENCE, which a broadened ignore rule leaves undisturbed.
#
# The check is on the PATH, via `git check-ignore`, never a grep of `.gitignore`: a grep passes on
# a commented-out rule, and on a rule that a later `!` negation cancels.
#
# And it is `-q`, never `-v`. Only `-q`'s exit status answers "is this path ignored". With `-v`,
# exit 0 means "some pattern matched" — and a NEGATED pattern matching counts, so
# `!.claude/worktrees/` placed just after the rule makes `check-ignore -v` exit 0 while the path is
# not ignored at all. That is a fail-open in precisely the case check-ignore was chosen to catch.
#
# The paths are queried WITH a trailing slash. `.claude/worktrees/` is a directory-only pattern and
# check-ignore cannot tell a non-existent path is a directory, so on a fresh checkout
# `check-ignore -q .claude/worktrees` answers "not ignored" for a rule that is perfectly correct,
# while `.claude/worktrees/` answers correctly. Querying with the slash is what lets this script
# stay READ-ONLY rather than mkdir-ing scratch directories into the workspace it is auditing.
# tests/worktrees-ignored/test.sh drives that exact case, so dropping the slash goes red.
#
# Usage:
#   worktrees-ignored.sh [-C <repo-path>]
#
# Exit codes:
#   0  every worktree home is ignored, and the rule was not broadened
#   1  a worktree home is NOT ignored — `git add -A` would stage a worktree
#   2  the rule was broadened and now hides .claude/skills/repo-profile.md
#   3  usage error, or <repo-path> is not a git repository

set -euo pipefail

REPO="."

# Print the header block above as the help text, the way the sibling guards in
# skills/implement-issue/scripts do — a hardcoded line range there silently stops documenting the
# exit codes, and ci.yml greps --help for exactly that string.
usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -C) [ -n "${2:-}" ] || { printf 'worktrees-ignored: -C needs a <repo-path>\n' >&2; exit 3; }
        REPO="$2"; shift 2 ;;
    *)  printf 'worktrees-ignored: unexpected argument: %s\n' "$1" >&2; exit 3 ;;
  esac
done

git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || {
  printf 'worktrees-ignored: %s is not a git repository\n' "$REPO" >&2; exit 3; }

# Trailing slashes are load-bearing — see the header.
WORKTREE_HOMES=".claude/worktrees/ .worktrees/"
MUST_STAY_VISIBLE=".claude/skills/repo-profile.md"

failed=0
for home in $WORKTREE_HOMES; do
  if git -C "$REPO" check-ignore -q "$home"; then
    printf 'worktrees-ignored: ok — %s is ignored\n' "$home"
  else
    failed=1
    printf 'worktrees-ignored: REFUSED — %s is NOT ignored.\n' "$home" >&2
    printf '  A worktree left there is staged by any `git add -A` run in this repo, as one\n' >&2
    printf '  gitlink (160000) pointing at a commit no clone can fetch — see #43.\n' >&2
    printf '  fix: add "%s" to .gitignore.\n' "$home" >&2
  fi
done
[ "$failed" -eq 0 ] || exit 1

if git -C "$REPO" check-ignore -q "$MUST_STAY_VISIBLE"; then
  printf 'worktrees-ignored: REFUSED — %s is ignored.\n' "$MUST_STAY_VISIBLE" >&2
  printf '  The rule was broadened (most likely to `.claude/`). Consumer repos are told to COMMIT\n' >&2
  printf '  that file — it is how the lifecycle skills read repo facts — and this repo is the\n' >&2
  printf '  reference they copy, so the narrow path is the point, not an oversight.\n' >&2
  printf '  fix: ignore the worktree homes specifically, not all of .claude/.\n' >&2
  exit 2
fi
printf 'worktrees-ignored: ok — %s is still visible\n' "$MUST_STAY_VISIBLE"
