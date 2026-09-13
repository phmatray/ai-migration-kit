#!/usr/bin/env bash
# capable.sh — can this skill run against this host? The program of the registered decision
# `tracker.capable` (#505).
#
# It is not called by hand: `scripts/decide.sh tracker.capable` runs it, logs the branch that fired,
# and refuses a word outside the vocabulary declared in `decisions/registry.json`. Step 1 of every
# lifecycle skill reaches it through `skills/_shared/preconditions.md`, which pipes
# `tracker.sh state <skill>` into it.
#
# Usage: capable.sh < state.json
#   Reads the report `scripts/tracker.sh state <skill>` prints — {tracker, detail, skill, needs,
#   implements} — from stdin. Prints ONE line of JSON on stdout: the verdict word, and the name of
#   the precedence rule that produced it.
#   Verdict words: capable | missing | unsupported
#
# THIS PROGRAM READS NO FILES AND RUNS NO COMMANDS. It sees only the state it is handed, which is
# what lets `tests/tracker/test.sh` pin every branch with a fixture instead of building five
# repositories. The dispatcher gathers the facts; this decides on them; neither does the other's job.
#
# Precedence, top to bottom — the FIRST matching rule decides:
#
#    #  when                                        verdict      rule name
#    1  the tracker is github                       capable      github-reference
#    2  there is no backend at all                  unsupported  no-backend
#    3  the skill is not on the contract            missing      skill-not-on-contract
#    4  the backend lacks a verb the skill needs    missing      verb-not-implemented
#    5  anything else                               capable      backend-covers-skill
#
# The orderings, recorded here because they have to be decided ONCE rather than re-derived by
# whoever reads the prose next:
#
#   * RULE 1 OUTRANKS EVERYTHING, and it is the rule that makes this change a no-op on GitHub. Every
#     skill still calls `gh` directly today, and those calls are CORRECT on GitHub — so a skill that
#     has not migrated yet must not be refused there for the absence of a contract entry it does not
#     use. GitHub is the reference backend; asking whether it "implements enough" would answer no for
#     every unmigrated skill and break the whole kit on its own host.
#   * `unsupported` (2) IS NOT `missing` (3, 4). They ask different questions of a reader and deserve
#     different sentences: `unsupported` means nobody has written a backend for this host, so the
#     answer is to write one; `missing` means the backend exists but this skill's verbs are not on it
#     yet, so the answer is to migrate the skill or add the verb. Collapsing them would leave the
#     Step 1 refusal unable to say which.
#   * RULE 3 IS REACHED ONLY ON A NON-GITHUB HOST, because rule 1 has already answered for GitHub.
#     `needs` is null for every skill today — the contract's `skills` map is deliberately empty until
#     the first skill migrates — so on a second host every skill answers `missing` until somebody
#     puts its verbs on the contract. That is the intended gate, not an oversight: it is what makes
#     "create-issue works on GitLab, merge-pr does not yet" a statement the kit can actually make.
#   * RULE 4 SUBTRACTS `implements` FROM `needs`, so a backend that implements MORE than the skill
#     needs is still capable. The question is whether the skill's verbs are covered, never whether
#     the two lists are equal.
set -euo pipefail

json=$(cat)

command -v jq > /dev/null 2>&1 || {
  echo "capable: jq is missing — it is a \`required\` prerequisite in requirements.json" >&2
  exit 2
}

verdict=$(printf '%s' "$json" | jq -c '
  if   .tracker == "github"                   then {verdict:"capable",     rule:"github-reference"}
  elif (.implements == null)                  then {verdict:"unsupported", rule:"no-backend"}
  elif (.needs == null)                       then {verdict:"missing",     rule:"skill-not-on-contract"}
  elif (((.needs - .implements) | length) > 0) then {verdict:"missing",    rule:"verb-not-implemented"}
  else                                             {verdict:"capable",     rule:"backend-covers-skill"}
  end
')

printf '%s\n' "$verdict"
