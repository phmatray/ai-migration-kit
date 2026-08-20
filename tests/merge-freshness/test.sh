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
# SKILL.md Step 4 currently restates the same rule as prose for the agent to apply by hand; this
# suite does not read that prose, so it cannot catch the two drifting apart (tracked in #171's
# follow-up — see the PR description).
set -euo pipefail
cd "$(dirname "$0")/../.."

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$KIT_ROOT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT_ROOT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT_ROOT"

VERDICT_SCRIPT="$KIT_ROOT/skills/merge-pr/scripts/merge-verdict.sh"
FIXTURES="$KIT_ROOT/tests/merge-freshness/fixtures"

[ -x "$VERDICT_SCRIPT" ] || {
  echo "FAIL: $VERDICT_SCRIPT is missing or not executable"; exit 1; }

FAILED=0
note_fail() { echo "FAIL: $1"; FAILED=1; }

verdict() {
  local fixture="$1" want="$2" what="$3"
  local path="$FIXTURES/$fixture" out rc=0
  if [ ! -r "$path" ]; then
    note_fail "$fixture — fixture missing ($what)"
    return 0
  fi
  out=$("$VERDICT_SCRIPT" "$path" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    note_fail "$fixture — merge-verdict.sh exited $rc ($what):
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

if [ "$FAILED" -ne 0 ]; then
  echo
  echo "merge-freshness: FAILED"
  exit 1
fi
echo
echo "merge-freshness: OK — a stale CLEAN state syncs instead of merging."
