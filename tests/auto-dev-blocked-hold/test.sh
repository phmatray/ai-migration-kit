#!/usr/bin/env bash
# Golden test for the auto-dev BLOCKED verdict becoming a native hold (#511).
#
# A worker's `BLOCKED` report used to die with the run that paid for it: nothing wrote the
# blocker back anywhere the next `survey.sh` reads, so a re-dispatched worker re-found the same
# prerequisite or re-plan block from scratch. The fix gives the worker's final line a structured
# `BLOCKED_BY:` field (`commands/auto-dev-worker.md`) and has the supervisor write it back as a
# native hold (`skills/auto-dev/SKILL.md` Step 4) — a `blocked_by` edge for a prerequisite, an
# assignment for a re-plan — never tier-escalating either shape. This repo has no harness that
# runs `auto-dev` end-to-end, so this suite pins the textual invariants of the two rendered docs
# (the established pattern — see tests/auto-dev-worktree-field/test.sh).
set -euo pipefail
cd "$(dirname "$0")/../.."
KIT="$PWD"

. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"

fail() { echo "FAIL: $1"; exit 1; }

WORKER_MD="$KIT/commands/auto-dev-worker.md"
SKILL_MD="$KIT/skills/auto-dev/SKILL.md"
[ -f "$WORKER_MD" ] || fail "missing $WORKER_MD"
[ -f "$SKILL_MD" ] || fail "missing $SKILL_MD"

# --------------------------------------------------------------- Task 2: the worker's final line

# 1. The required final line ends in a BLOCKED_BY: field.
grep -qE '^PHASE1 \| ISSUE: .* \| BLOCKED_BY:' "$WORKER_MD" \
  || fail "commands/auto-dev-worker.md's required final line does not end in BLOCKED_BY:"

# 2. Its grammar names all three shapes.
grep -qF '#a[,#b]' "$WORKER_MD" \
  || fail "commands/auto-dev-worker.md's BLOCKED_BY grammar does not name #a[,#b]"
grep -qF 'replan' "$WORKER_MD" \
  || fail "commands/auto-dev-worker.md's BLOCKED_BY grammar does not name replan"
grep -qE 'BLOCKED_BY.*none|none.*BLOCKED_BY' "$WORKER_MD" \
  || fail "commands/auto-dev-worker.md's BLOCKED_BY grammar does not name none"

# 3. A missing field reads as none (an older worker's report).
grep -qE 'missing.{0,40}reads as `?none`?|a missing field reads as `?none`?' "$WORKER_MD" \
  || fail "commands/auto-dev-worker.md does not say a missing BLOCKED_BY field reads as none"

echo "PASS: auto-dev-blocked-hold"
