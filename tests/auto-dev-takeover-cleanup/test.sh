#!/usr/bin/env bash
# Golden test for the auto-dev takeover's local cleanup (#227).
#
# `skills/auto-dev/SKILL.md` Step 4's takeover bullet lets the supervisor land a stalled PR itself
# via `guarded-pr-merge.sh` when a worker idles at "ready" twice with CI already final. On a `0`
# (MERGED) verdict, the prose used to stop at "shut the worker down and refill the slot" — the
# script's own header comment is explicit that "local cleanup (branch/worktree teardown) is the
# caller's job", and nothing was ever the caller. Every landed takeover therefore leaked the
# worker's `.claude/worktrees/<branch>/` checkout and local head branch forever, with no follow-up
# triage either — the same guarantee every other merged PR in this kit gets via `merge-pr` Steps
# 6-7, just never invoked here.
#
# The fix adds a dispatch of a fresh one-shot `merge-pr <PR>` session after the takeover's MERGED
# verdict — `merge-pr`'s own Step 1 resume contract detects `state == MERGED` and routes straight
# to Steps 6-7 (follow-up triage, then worktree/branch teardown), so the dispatch is pure cleanup
# with no risk of a second merge attempt. This suite pins the textual invariants so none regresses
# silently again; it asserts SKILL.md prose, not runtime behavior — this repo has no harness that
# runs `auto-dev` end-to-end, so its golden suites for this skill assert structural properties of
# the doc itself (see tests/auto-dev-never-wait/test.sh for the established pattern).
set -euo pipefail
cd "$(dirname "$0")/../.."
KIT="$PWD"

. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"

fail() { echo "FAIL: $1"; exit 1; }

SKILL_MD="$KIT/skills/auto-dev/SKILL.md"
[ -f "$SKILL_MD" ] || fail "missing $SKILL_MD"

# 1. The MERGED clause dispatches a fresh merge-pr session for cleanup, not just a slot refill.
grep -qF 'dispatch a fresh one-shot session running `merge-pr <PR>`' "$SKILL_MD" \
  || fail "SKILL.md's takeover MERGED clause does not dispatch a fresh merge-pr session"

# 2. It names the plugin-namespaced form, following the same rule Step 1 states for other
#    dispatched skill names (e.g. `ai-migration-kit:auto-dev-worker`).
grep -qF '`ai-migration-kit:merge-pr <PR>`' "$SKILL_MD" \
  || fail "SKILL.md does not name the fully-qualified ai-migration-kit:merge-pr form"

# 3. It states WHY a second merge can never happen: merge-pr's own resume contract routes an
#    already-MERGED PR straight to Steps 6-7.
grep -qF 'state == MERGED' "$SKILL_MD" \
  || fail "SKILL.md does not explain merge-pr's MERGED resume routing"
grep -qF 'Steps 6-7' "$SKILL_MD" \
  || fail "SKILL.md does not point the dispatch at merge-pr's Steps 6-7 (follow-ups + teardown)"

# 4. It scopes the call to cleanup only, and defers "fully closed" bookkeeping to that session's
#    own report rather than the takeover step alone.
grep -qF 'local cleanup only' "$SKILL_MD" \
  || fail "SKILL.md does not scope the dispatched session to local cleanup only"
grep -qF 'fully closed' "$SKILL_MD" \
  || fail "SKILL.md does not defer 'fully closed' slot bookkeeping to the cleanup session's report"

# 5. A failed/timed-out cleanup session must not block the fleet — surfaced like any other
#    dispatched-session failure, not treated as an outstanding merge problem.
grep -qF "don't block the fleet on it" "$SKILL_MD" \
  || fail "SKILL.md does not say a failed/timed-out cleanup session must not block the fleet"

echo "PASS: auto-dev-takeover-cleanup"
