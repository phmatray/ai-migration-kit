#!/usr/bin/env bash
# skills/merge-pr/scripts/merge-verdict.sh — the freshness/mergeability decision for merge-pr (#171).
#
# Finding: GitHub's `mergeStateStatus` only ever reports `BEHIND` when the base branch has "require
# branches to be up to date before merging" enabled. Without that protection rule a branch that is
# arbitrarily far behind its base reports `CLEAN` — GitHub is answering "does this merge cleanly",
# not "was this tested against what it will merge into". Measured landing #147: green check-runs,
# `mergeStateStatus: CLEAN`, and the branch six commits and 95 minutes behind `main`.
#
# So `behind_by` — the branch's measured divergence from its base — is read directly and takes
# precedence over `mergeStateStatus`. This makes the decision identical on repos with branch
# protection on or off, instead of silently disabling the freshness guard on the (more common) repos
# that leave it off.
#
# Usage: merge-verdict.sh [<state.json>]
#   Reads a JSON object with behind_by, mergeStateStatus, isDraft, failed, pending from the given
#   file, or from stdin when no file is given. Prints exactly one word on stdout and exits 0:
#     merge | sync | fix-check | wait | ready | review
set -euo pipefail

usage() {
  echo "usage: merge-verdict.sh [<state.json>]" >&2
  echo "  reads {behind_by, mergeStateStatus, isDraft, failed, pending} from the file, or from" >&2
  echo "  stdin when no file is given, and prints one word: merge|sync|fix-check|wait|ready|review" >&2
}

INPUT="${1:-}"
if [ -n "$INPUT" ]; then
  [ -r "$INPUT" ] || { echo "merge-verdict: cannot read '$INPUT'" >&2; usage; exit 2; }
  json=$(cat "$INPUT")
else
  json=$(cat)
fi

command -v jq > /dev/null 2>&1 || {
  echo "merge-verdict: jq is missing — it is a \`required\` prerequisite in requirements.json" >&2
  exit 2
}

# Precedence, top to bottom — the FIRST matching rule decides:
#   1. any check still pending      -> wait       (nothing to judge yet)
#   2. any check failed             -> fix-check  (a red bar outranks everything else)
#   3. the PR is a draft            -> ready       (flip it, then re-derive)
#   4. behind_by > 0                -> sync         (#171 — this IS the BEHIND correction, read
#                                                     directly instead of waiting for GitHub to say
#                                                     so, which it only does under branch protection)
#   5. mergeStateStatus == DIRTY    -> sync         (conflicts with the base)
#   6. mergeStateStatus == BLOCKED  -> review        (a branch-protection gate is unmet)
#   7. mergeStateStatus == CLEAN    -> merge         (done)
#   8. anything else (UNKNOWN, or a state this script does not recognise) -> wait
verdict=$(printf '%s' "$json" | jq -r '
  if   ((.pending // [])       | length) > 0        then "wait"
  elif ((.failed  // [])       | length) > 0        then "fix-check"
  elif (.isDraft // false)                          then "ready"
  elif ((.behind_by // 0) | tonumber)      > 0        then "sync"
  elif .mergeStateStatus == "DIRTY"                 then "sync"
  elif .mergeStateStatus == "BLOCKED"               then "review"
  elif .mergeStateStatus == "CLEAN"                 then "merge"
  else                                                    "wait"
  end
')

printf '%s\n' "$verdict"
