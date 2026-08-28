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
# This is the program of the registered decision `merge.step4` (#208). It is not called by hand:
# `scripts/decide.sh merge.step4` runs it, logs the branch that fired, and refuses a word outside
# the vocabulary declared in `decisions/registry.json`. SKILL.md Step 4 used to restate this same
# precedence as a markdown table for the agent to apply BY HAND; that table is gone, and
# `scripts/decision-check.py` (R7, R8) is what keeps it gone.
#
# Usage: merge-verdict.sh [<state.json>]
#   Reads a JSON object with behind_by, mergeStateStatus, isDraft, reviewDecision, failed,
#   pending and unresolved_threads from the given file, or from stdin when no file is given. Prints ONE line of JSON on
#   stdout and exits 0: the verdict word, and the name of the precedence rule that produced it.
#   Verdict words: merge | sync | fix-check | wait | ready | review
#
# WHY A NAMED RULE AND NOT JUST A WORD. `behind` and `dirty` both answer sync, so the word alone
# cannot say which branch fired — which makes each precedence rule independently unpinnable in a
# fixture, and makes the event log's central question ("does this gate redden repeatedly on ONE
# cause?") unanswerable. The rule name is the identity of the branch; the word is only the action.
set -euo pipefail

usage() {
  echo "usage: merge-verdict.sh [<state.json>]" >&2
  echo "  reads {behind_by, mergeStateStatus, isDraft, reviewDecision, failed, pending," >&2
  echo "  unresolved_threads} from the" >&2
  echo "  file, or from stdin when no file is given, and prints one JSON line naming the action" >&2
  echo "  (merge|sync|fix-check|wait|ready|review) and the precedence rule that chose it" >&2
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

# Precedence, top to bottom — the FIRST matching rule decides. Fourteen rules, not eight, so that
# every state Step 4's deleted table enumerated has a branch here that ACTS on it, rather than
# falling into a catch-all the prose then had to explain around.
#
#    #  when                                    action     rule name
#    1  a check is still pending                wait       pending
#    2  a check failed                          fix-check  failed
#    3  the PR carries the draft flag           ready      draft-flag
#    4  the merge state says DRAFT              ready      draft-state
#    5  behind_by > 0                           sync       behind
#    6  the merge state says BEHIND             sync       behind-state
#    7  the merge state says DIRTY              sync       dirty
#    8  BLOCKED, review says changes requested  review     blocked-changes-requested
#    9  a review thread is unresolved           review     unresolved-threads
#   10  BLOCKED, anything else                  review     blocked-approval
#   11  the merge state says UNSTABLE           wait       unstable-quiet
#   12  the merge state says CLEAN              merge      clean
#   13  the merge state says UNKNOWN            wait       unknown
#   14  anything else                           wait       unrecognised
#
# The orderings, recorded here because extraction forces them to be decided ONCE instead of being
# re-derived by whoever reads the prose next:
#
#   * DRAFT (3,4) OUTRANKS FRESHNESS (5,6). This is the shipped order, kept deliberately: a draft
#     is not a merge candidate at all, so measuring its staleness first would send an agent to sync
#     a branch nobody has asked to land.
#   * PENDING/FAILED (1,2) OUTRANK DRAFT. A draft PR with a red check answers fix-check, not ready:
#     fix the check rather than flip the PR first, because flipping it only publishes the red bar.
#     SKILL.md Step 3 states this as a flat conjunction (no failures AND no pending AND not draft);
#     the conjunction does not order its terms, and this is where that difference is resolved.
#   * RULE 6 IS A REAL REACHABLE GAP, not a hypothetical. The compare read and the pr-view read are
#     sequential and non-atomic, so a sibling PR merging BETWEEN them yields behind_by 0 alongside
#     a merge state of BEHIND — which the eight-rule version answered wait, i.e. hang.
#   * BLOCKED KEEPS ONE VERDICT WORD and splits into TWO rule names by reading reviewDecision. Two
#     causes, one action, no vocabulary inflation — and the event log can still tell "waiting on an
#     approval" from "someone asked for changes", which is the whole reason the split is worth
#     having.
#   * UNRESOLVED THREADS (9) SIT BELOW CI/DRAFT/SYNC, AND BETWEEN THE TWO BLOCKED RULES. Rule 9
#     exists because the `review` verdict used to be reachable ONLY through a BLOCKED merge state,
#     and a bot posting a COMMENTED review — which is what GitHub's code-quality bot posts — sets
#     neither reviewDecision nor BLOCKED. Its findings fell through to `clean` and merged unread
#     (#294; measured on horizon-hub #956 and #957 — four and one unresolved thread, merged 54 and
#     34 minutes after the bot first commented, so not a timing race). It sits BELOW 1-7 because
#     answering review comments against a red or stale diff is work the next push invalidates.
#     It yields to 8 because an explicit human CHANGES_REQUESTED is the more specific cause and
#     deserves to keep its name in the log — same word, same correction, so nothing is lost by
#     letting it win. It OUTRANKS 10 because `blocked-approval` is the one rule SKILL.md answers
#     with "surface it and stop": leaving an un-actionable approval wait above open threads would
#     hide them exactly the way `clean` did.
#   * RULE 9 IS CLEARED BY RESOLVING A THREAD, NOT ONLY BY CHANGING CODE. A gate only a code change
#     can clear deadlocks an autonomous fleet on the first bot finding the agent judges wrong or
#     cannot satisfy — a worse bug than the one this rule fixes. Both routes SKILL.md already
#     sanctions clear it: fix the ask, push, resolve; or reply on the thread with the reasoning and
#     then resolve it. Resolving SILENTLY is the one move forbidden. This verdict says "go read
#     them", never "obey them".
#   * `mergeable` IS NOT READ. SKILL.md Step 4 fetched it and nothing ever consumed it; a field
#     that is fetched and unread is the shape of the `behind`-versus-`behind_by` bug this exists
#     to make impossible.
#   * RULE 11 SHIPS WITH AN ANSWER I AM NOT CERTAIN OF. UNSTABLE with both check sets empty is a
#     state the old table gave an action for and this program cannot act on. It answers wait, and
#     the event log will say how often that happens. If it is common, wait is a hang — and the
#     ratchet finding that is the mechanism working, not the mechanism failing.
verdict=$(printf '%s' "$json" | jq -c '
  if   ((.pending // []) | length) > 0     then {verdict:"wait",      rule:"pending"}
  elif ((.failed  // []) | length) > 0     then {verdict:"fix-check", rule:"failed"}
  elif (.isDraft // false)                 then {verdict:"ready",     rule:"draft-flag"}
  elif .mergeStateStatus == "DRAFT"        then {verdict:"ready",     rule:"draft-state"}
  elif ((.behind_by // 0) | tonumber) > 0  then {verdict:"sync",      rule:"behind"}
  elif .mergeStateStatus == "BEHIND"       then {verdict:"sync",      rule:"behind-state"}
  elif .mergeStateStatus == "DIRTY"        then {verdict:"sync",      rule:"dirty"}
  elif .mergeStateStatus == "BLOCKED" and .reviewDecision == "CHANGES_REQUESTED"
                                           then {verdict:"review",    rule:"blocked-changes-requested"}
  elif ((.unresolved_threads // []) | length) > 0
                                           then {verdict:"review",    rule:"unresolved-threads"}
  elif .mergeStateStatus == "BLOCKED"      then {verdict:"review",    rule:"blocked-approval"}
  elif .mergeStateStatus == "UNSTABLE"     then {verdict:"wait",      rule:"unstable-quiet"}
  elif .mergeStateStatus == "CLEAN"        then {verdict:"merge",     rule:"clean"}
  elif .mergeStateStatus == "UNKNOWN"      then {verdict:"wait",      rule:"unknown"}
  else                                          {verdict:"wait",      rule:"unrecognised"}
  end
')

printf '%s\n' "$verdict"
