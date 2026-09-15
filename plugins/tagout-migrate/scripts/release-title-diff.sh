#!/usr/bin/env bash
# release-title-diff.sh — list the paths a pull request changes, NUL-separated, fail-closed.
#
# Split out of the CI `run:` block, because inline it failed OPEN. The first version was:
#
#     mapfile -t changed < <(git diff --name-only ... )
#     if [ ${#changed[@]} -eq 0 ]; then echo "nothing to gate"; exit 0; fi
#
# `mapfile` reports its own status, never that of the process substitution, and neither `set -e`
# nor `pipefail` reaches inside `< <(…)`. So any git failure — a sha missing from the object DB,
# a stale refs/pull/N/merge — yielded an empty array, which the next line read as "nothing to
# gate" and passed. A gate that skips itself when its input is broken is the exact defect the
# gate exists to prevent, and it was invisible precisely because the comment beside it asserted
# the opposite. Here the exit status is the answer, so an empty list can never be mistaken for a
# failure to produce one.
#
# Usage: release-title-diff.sh <base-sha> <head-sha>
#   stdout  one NUL-terminated path per changed file (possibly none)
#   exit 0  the list is authoritative — empty means the diff really is empty
#   exit 1  the list could NOT be computed; the caller must fail, never read it as "not applicable"
#
# Operates on the git repository of the current working directory (unlike the other kit scripts,
# which are cwd-independent): a diff has no meaning without a repository to take it in.

set -euo pipefail

die() { printf 'release-title-diff: %s\n' "$*" >&2; exit 1; }

[ $# -eq 2 ] || die "usage: release-title-diff.sh <base-sha> <head-sha>"

BASE_REF="$1"
HEAD_REF="$2"

[ -n "$BASE_REF" ] || die "empty base sha — the pull_request payload carried none"
[ -n "$HEAD_REF" ] || die "empty head sha — the pull_request payload carried none"

for sha in "$BASE_REF" "$HEAD_REF"; do
  git cat-file -e "${sha}^{commit}" 2>/dev/null || die \
"commit $sha is not present in this clone.
  On a pull_request run this usually means the merge ref is stale — the PR conflicts with its
  base, or a fork force-pushed. Refusing to report an empty change set, which would silently
  skip the release-title gate."
done

merge_base=$(git merge-base "$BASE_REF" "$HEAD_REF") \
  || die "no merge base between $BASE_REF and $HEAD_REF"

# -z rather than plain --name-only: git C-quotes any path holding a quote, backslash, tab or
# control character, and core.quotePath=false only spares non-ASCII bytes. A quoted path stops
# matching an anchored prefix such as skills/*, which would be another silent pass. NUL
# separation has no escaping at all.
# --no-renames so that a rename *out of* skills/** still reports its old path — moving a skill
# away is a change to skills/**.
git -c core.quotePath=false diff -z --name-only --no-renames "$merge_base" "$HEAD_REF" \
  || die "git diff failed between $merge_base and $HEAD_REF"
