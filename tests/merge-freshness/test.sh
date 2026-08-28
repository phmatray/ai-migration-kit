#!/usr/bin/env bash
# Golden test for merge-pr's freshness verdict (#171).
#
# `merge-pr` used to decide whether to sync a branch with its base by reading
# `mergeStateStatus` alone. GitHub only ever emits its `BEHIND` value when the base branch
# requires branches to be up to date before merging — without that protection rule a branch
# arbitrarily far behind reports `CLEAN`, and the sync row in Step 4's table is unreachable.
#
# Measured landing #147: head sha `3a30dfd` had green check-runs, `mergeStateStatus: CLEAN`, and
# was six commits / 95 minutes behind `main` when `/merge-pr 147` read the state. A literal
# application of the old table merged it, having verified nothing about the combination it was
# actually landing. This suite pins that exact fixture, plus the four other rows the fix's spec
# lays out, against `skills/merge-pr/scripts/merge-verdict.sh` — the reference implementation of
# the precedence rule, so a rewrite of ITS ordering goes red here instead of shipping quietly.
# The same class landed a second time (#294), from the other end. Every path into the `review`
# verdict required `mergeStateStatus == BLOCKED`, so a bot posting a COMMENTED review — which sets
# neither `reviewDecision` nor a BLOCKED state — fell through to `merge`/`clean` and its findings
# were never read. Measured on bsca-dev/horizon-hub: #956 merged 11:18Z with 4 unresolved threads
# (bot first commented 10:24Z), #957 merged 11:49Z with 1 (bot at 11:15Z) — 54 and 34 minutes, so
# not a timing race. The `threads-*` fixtures below pin the rule that closes it AND, one fixture
# per claim, every rule it must NOT preempt.
#
# The restatement is gone (#208): SKILL.md Step 4 no longer carries a `mergeStateStatus` table for
# the agent to apply by hand — it INVOKES this decision through `scripts/decide.sh merge.step4`.
# What keeps it gone is not this suite, which still reads no prose, but `scripts/decision-check.py`
# — R7 refuses an owner that stops invoking its decision, and R8 refuses a markdown table that
# re-enumerates the states this program tests.
set -euo pipefail
cd "$(dirname "$0")/../.."

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$KIT_ROOT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT_ROOT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT_ROOT"

# The decision is reached the way merge-pr reaches it: through the dispatcher, by id. Calling the
# script directly would test a path no caller uses, and would skip the vocabulary refusal that
# turns an unregistered verdict word into a red build.
VERDICT_SCRIPT="$KIT_ROOT/scripts/decide.sh"
FIXTURES="$KIT_ROOT/tests/merge-freshness/fixtures"

[ -x "$VERDICT_SCRIPT" ] || {
  echo "FAIL: $VERDICT_SCRIPT is missing or not executable"; exit 1; }

# Telemetry into the scratch dir, never the checkout: a suite must not append to the developer's
# own event log, and `2>&1` below would fold any refusal about the log into the verdict string.
WORK=$(kit_scratch)
KIT_DECISION_LOG="$WORK/decision-events.jsonl"
export KIT_DECISION_LOG

FAILED=0
note_fail() { echo "FAIL: $1"; FAILED=1; }

verdict() {
  local fixture="$1" want="$2" what="$3"
  local path="$FIXTURES/$fixture" out rc=0
  if [ ! -r "$path" ]; then
    note_fail "$fixture — fixture missing ($what)"
    return 0
  fi
  out=$("$VERDICT_SCRIPT" merge.step4 "$path" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    note_fail "$fixture — decide.sh merge.step4 exited $rc ($what):
$(printf '%s\n' "$out" | sed 's/^/      /')"
    return 0
  fi
  if [ "$out" != "$want" ]; then
    note_fail "$fixture — $what
      want: $want
      got:  $out"
    return 0
  fi
  echo "ok: $fixture — $what"
}

# `review` is now THREE rules wearing one word — blocked-changes-requested, unresolved-threads and
# blocked-approval — so an assertion on the word alone cannot tell which branch fired, and a
# mis-ordering of the three would pass every check above. This helper reads `--json` and pins the
# RULE, which is the identity of the branch; the word is only the action. Same reasoning the
# program's own header gives for naming its rules at all.
verdict_rule() {
  local fixture="$1" want="$2" what="$3"
  local path="$FIXTURES/$fixture" out got rc=0
  if [ ! -r "$path" ]; then
    note_fail "$fixture — fixture missing ($what)"
    return 0
  fi
  out=$("$VERDICT_SCRIPT" merge.step4 --json "$path" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    note_fail "$fixture — decide.sh merge.step4 --json exited $rc ($what):
$(printf '%s\n' "$out" | sed 's/^/      /')"
    return 0
  fi
  got=$(printf '%s' "$out" | jq -r '"\(.verdict)/\(.rule)"' 2>/dev/null) || got="<unparseable: $out>"
  if [ "$got" != "$want" ]; then
    note_fail "$fixture — $what
      want: $want
      got:  $got"
    return 0
  fi
  echo "ok: $fixture — $what"
}

# The #147 case: green checks, CLEAN, six commits behind — the old table merged this. It must sync.
verdict behind-clean.json sync \
  "a branch 6 behind with a CLEAN state must SYNC (PR #147's exact state at 13:20 UTC; the old rule answered 'merge')"

verdict up-to-date-clean.json merge \
  'up to date and CLEAN merges'

verdict behind-only.json sync \
  'a protected repo reporting BEHIND still syncs (unchanged behaviour)'

verdict stale-dirty.json sync \
  'stale and conflicted syncs — behind_by takes precedence, DIRTY would sync anyway'

verdict unstable-red-check.json fix-check \
  'up to date, but a failing check must be fixed before anything else'

# The #294 case: green, CLEAN, up to date, no reviewDecision at all — and four unresolved threads
# from a COMMENTED bot review. Before the rule existed this was PR #956, and it merged.
verdict_rule threads-clean.json review/unresolved-threads \
  "a CLEAN, up-to-date PR with an unresolved thread must REVIEW (horizon-hub #956's state; the old precedence answered 'merge')"

verdict_rule threads-all-resolved.json merge/clean \
  'the same PR with every thread resolved still merges — the rule fires on open threads, not on having been reviewed'

# NON-PREEMPTION, one fixture per claim. There is no point sending an agent to answer review
# comments while CI is red or the branch is stale: the next push invalidates the diff they were
# written against, and the reviewer gets asked twice.
verdict_rule threads-pending.json wait/pending \
  'a still-running check outranks unresolved threads'

verdict_rule threads-red-check.json fix-check/failed \
  'a failed check outranks unresolved threads'

verdict_rule threads-draft.json ready/draft-flag \
  'a draft outranks unresolved threads — nobody has asked to land it yet'

verdict_rule threads-behind.json sync/behind \
  'a stale branch outranks unresolved threads'

# The two BLOCKED neighbours, which share the WORD `review` and are only distinguishable by rule.
verdict_rule threads-changes-requested.json review/blocked-changes-requested \
  'an explicit human CHANGES_REQUESTED keeps its name — same word, same correction, more specific cause'

verdict_rule threads-awaiting-approval.json review/unresolved-threads \
  "open threads outrank a required-approval wait — 'blocked-approval' is the rule SKILL.md answers with stop, and stopping would hide the threads again"

if [ "$FAILED" -ne 0 ]; then
  echo
  echo "merge-freshness: FAILED"
  exit 1
fi
echo
echo "merge-freshness: OK — a stale CLEAN state syncs, and an unresolved thread reviews, instead of merging."
