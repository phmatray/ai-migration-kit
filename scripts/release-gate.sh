#!/usr/bin/env bash
# release-gate.sh — refuse a change to skills/** that ships no version bump.
#
# The kit's skills are consumed through the plugin marketplace, and the installed copy is an
# install-time cache keyed by version — NOT a live view of this repo. Measured on issue #6: pulling
# the marketplace clone to a commit containing a fix left the loaded cache completely unchanged.
#
# So merging a skills fix without bumping .claude-plugin/plugin.json ships it to nobody, while
# looking exactly like a successful release: green CI, commit on main, and every consumer still
# running the old code. That is what happened to PR #5 — a data-loss fix that reached zero users.
#
# This gate makes that state unmergeable.
#
# Usage:
#   release-gate.sh <base-version> <head-version> <changed-files-file>
#
#   <changed-files-file>  one repo-relative path per line (e.g. from `gh pr diff --name-only`)
#
# Exit 0 = releasable. Exit 1 = a skills change with no version bump. Exit 2 = misuse.

set -euo pipefail

die() { printf 'release-gate: %s\n' "$*" >&2; exit 2; }

[ $# -eq 3 ] || die "usage: release-gate.sh <base-version> <head-version> <changed-files-file>"

BASE_VERSION="$1"
HEAD_VERSION="$2"
CHANGED="$3"

[ -n "$BASE_VERSION" ] || die "base version is empty"
[ -n "$HEAD_VERSION" ] || die "head version is empty"

# An unreadable list must fail closed. Treating it as "no files changed" would wave through
# exactly the change this gate exists to stop.
[ -f "$CHANGED" ] || die "changed-file list not readable: $CHANGED"

# Only a path *under* skills/ counts. `docs/writing-skills.md` and `tests/skills/…` must not trip it,
# so anchor at the start and require the directory separator.
if grep -qE '^skills/' "$CHANGED"; then
  skills_changed=1
else
  skills_changed=0
fi

if [ "$skills_changed" -eq 0 ]; then
  echo "release-gate: no skills/** change — version bump not required (version $HEAD_VERSION)"
  exit 0
fi

if [ "$BASE_VERSION" = "$HEAD_VERSION" ]; then
  {
    echo "release-gate: REFUSED — this PR changes skills/** but leaves the plugin version at $HEAD_VERSION."
    echo
    echo "  Consumers load an install-time cache keyed by version, not this repo. Merging as-is"
    echo "  ships the change to nobody while looking like a successful release (see issue #6)."
    echo
    echo "  Fix: bump \"version\" in .claude-plugin/plugin.json."
    echo
    echo "  skills/** paths changed in this PR:"
    grep -E '^skills/' "$CHANGED" | sed 's/^/    /'
  } >&2
  exit 1
fi

echo "release-gate: skills/** changed and version moved $BASE_VERSION → $HEAD_VERSION — releasable"
exit 0
