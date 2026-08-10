#!/usr/bin/env bash
# release-title-gate.sh — a PR that changes skills/** must carry a PR title release-please
# will actually release.
#
# Why this exists (#27). Consumers load an install-time cache keyed by plugin version, not a live
# view of this repo (#6), so a skills fix that ships without a release reaches nobody while CI is
# green and `main` looks correct. #7 enforced that with a per-PR version bump; #14 retired it when
# release-please was installed, correctly — release-please inverts the rule, feature PRs never
# bump, the release PR does. The replacement guarantee is "every merged fix lands in the next
# release PR", and it holds only if the commit landing on `main` carries a type release-please
# releases. Nothing checked that.
#
# It checks the TITLE, not the branch commits, because this repo squash-merges: the PR title is
# what becomes the commit on `main`. Asserting the branch commits would fail PRs that land
# perfectly well — that is what made #7's gate untenable, and it would have failed PR #20, which
# was correct. That coupling is recorded in release-please-config.json.
#
# Usage:
#   release-title-gate.sh <pr-title> <changed-file…>
#
# Exit codes:
#   0  pass — either no changed path is under skills/**, or the title is releasable
#   1  refuse — the title would land a skills change that cuts no release
#   2  usage / plumbing error — the caller did not supply what the gate needs to decide
#
# Takes everything as arguments and reads no files, so it runs from any working directory and
# needs no secrets (fork PRs must be able to run it).

set -euo pipefail

# --------------------------------------------------------------------- the releasable set
# SINGLE SOURCE, and measured rather than assumed. release-please decides whether to cut a
# release at all by filtering commits through DEFAULT_CHANGELOG_SECTIONS
# (release-please, src/util/filter-commits.ts) and skipping the release when nothing user-facing
# survives. Visible in that table — hence releasable:
#     feat, fix, perf, revert
# Hidden there — hence NOT releasable:
#     chore, docs, style, refactor, test, build, ci
# `feature` appears in neither list, so it is filtered out too and cuts no release.
# A breaking change is releasable whatever its type: filter-commits.ts keeps a hidden-section
# commit that carries a BREAKING CHANGE note, which is what the `!` marker produces — that is
# the rule applied further down, and it comes from the same table, not from intuition.
# This repo runs release-type `simple` with no changelog-sections override
# (release-please-config.json), so those defaults are the ones in force. Override them there and
# this list has to move with them.
RELEASABLE_TYPES="feat fix perf revert"

die() { printf 'release-title-gate: REFUSED — %s\n' "$*" >&2; exit 1; }

usage() {
  cat >&2 <<'EOF'
usage: release-title-gate.sh <pr-title> <changed-file…>

  <pr-title>       the pull request title, verbatim (github.event.pull_request.title)
  <changed-file…>  every path the PR touches, one per argument
EOF
}

[ $# -ge 1 ] || { usage; exit 2; }

# Only when it is the sole argument. $1 is the PR title in the CI call, so an unguarded
# `-h|--help` case meant a pull request *titled* `--help` printed usage and exited 0 — a
# fail-open in a script whose whole contract is to fail closed.
if [ $# -eq 1 ]; then
  case "$1" in
    -h|--help) usage; exit 0 ;;
  esac
fi

TITLE="$1"; shift

# Zero paths is a broken caller, not an empty diff — refuse rather than silently conclude that
# skills/** is untouched. A diff step that produces nothing is the class of hole this gate exists
# to close, so it must not read as "not applicable".
[ $# -ge 1 ] || {
  printf 'release-title-gate: no changed paths supplied — cannot tell whether skills/** is touched.\n' >&2
  printf '  The caller (CI) must pass the merge-base diff; an empty list is a plumbing failure.\n' >&2
  exit 2
}

# --------------------------------------------------------------------- 1. is the gate relevant?
# Anchored at the repo root: docs/skills/… and .claude/skills/… are not the shipped skills.
touches_skills=0
for path in "$@"; do
  case "$path" in
    skills/*) touches_skills=1; break ;;
  esac
done

if [ "$touches_skills" -eq 0 ]; then
  echo "release-title-gate: no skills/** path in this change — not applicable."
  exit 0
fi

# --------------------------------------------------------------------- 2. parse the title
# Conventional Commits header: <type>[(scope)][!]: <description>
if [[ ! "$TITLE" =~ ^([A-Za-z]+)(\([^()]+\))?(!)?:\ +(.+)$ ]]; then
  die "this PR changes skills/**, and its title is not a Conventional Commits header.

  title:    $TITLE
  required: <type>[(scope)][!]: <description>   e.g. fix(merge-pr): stop dropping the follow-up list

  A subject is not a type. An issue-derived title such as 'CSV export: header row missing' reads
  conventional at a glance, but 'CSV export' is a subject, not one of feat|fix|chore|docs|…: the
  type comes first, as a single lowercase word, then an optional (scope), then ': '."
fi

type="${BASH_REMATCH[1]}"
breaking="${BASH_REMATCH[3]}"

# release-please matches types case-sensitively, so `Fix(skills):` is not `fix` and releases
# nothing. Refuse with the reason rather than letting it read as "not conventional".
if [ "$type" != "$(printf '%s' "$type" | tr '[:upper:]' '[:lower:]')" ]; then
  die "the type '$type' is not lowercase.

  release-please matches Conventional Commits types case-sensitively, so '$type' cuts no release.
  Retitle with '$(printf '%s' "$type" | tr '[:upper:]' '[:lower:]')'."
fi

# --------------------------------------------------------------------- 3. would it release?
if [ -n "$breaking" ]; then
  echo "release-title-gate: '$type!' carries the breaking-change marker — major release. OK."
  exit 0
fi

case " $RELEASABLE_TYPES " in
  *" $type "*)
    echo "release-title-gate: '$type' is releasable. OK."
    exit 0
    ;;
esac

die "this PR changes skills/**, but the type '$type' is not in the releasable set.

  title: $TITLE

  Consumers install a version-keyed cache of this plugin (#6), so a skills change only reaches
  them once release-please cuts a release — and this repo squash-merges, so the PR title above is
  the commit that release-please will read on main. A '$type:' commit cuts none: the change would
  sit on main, released later by some unrelated feat/fix, silently backdated into its notes.

  Retitle with one of: $RELEASABLE_TYPES — or add '!' if it really is a breaking change."
