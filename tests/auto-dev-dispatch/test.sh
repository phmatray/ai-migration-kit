#!/usr/bin/env bash
# Golden test for #412 — auto-dev dispatched every worker into the supervisor's OWN cwd.
#
# #314 moved workers from one-shot `claude -p` processes (which got their own cwd) to in-process
# background sub-agents (which inherit the supervisor's). Step 3's dispatch form was carried over
# unchanged, so the property the fleet's whole conflict strategy rests on — "one area per
# concurrent worker" — silently stopped being true whenever the supervisor itself ran in a
# worktree: every worker landed in that same tree instead of one of its own, and the first one to
# `git switch -c` moved every other worker's HEAD out from under it.
#
# This suite pins the textual invariants that fix it, one per plan task:
#   1. Step 3's dispatch form (both the phase-1 and phase-2 spawn blocks) carries the Agent tool's
#      `isolation: "worktree"` option, and *Gotchas* names the cwd-inheritance hazard.
#   2. commands/auto-dev-worker.md and commands/auto-dev-merge.md each state that the given
#      worktree IS the worktree — no nesting another one, no touching a path outside it.
#
# Reads only files under commands/ and skills/auto-dev/ — never samples/ — so no kit_guard is needed.
set -euo pipefail
cd "$(dirname "$0")/../.."
KIT="$PWD"

. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"

fail() { echo "FAIL: $1"; exit 1; }

SKILL_MD="$KIT/skills/auto-dev/SKILL.md"
WORKER_MD="$KIT/commands/auto-dev-worker.md"
MERGE_MD="$KIT/commands/auto-dev-merge.md"
[ -f "$SKILL_MD" ] || fail "missing $SKILL_MD"
[ -f "$WORKER_MD" ] || fail "missing $WORKER_MD"
[ -f "$MERGE_MD" ] || fail "missing $MERGE_MD"

# --- Task 1: isolation: "worktree" on BOTH spawn blocks in Step 3 -----------------------------
#
# Step 3 runs from its own heading to Step 4's; extracted with awk rather than grep -A so the
# window is exact regardless of how long the section grows, and so a later section is never
# accidentally included.
STEP3=$(awk '/^## Step 3 —/{flag=1} /^## Step 4 —/{flag=0} flag' "$SKILL_MD")
[ -n "$STEP3" ] || fail "skills/auto-dev/SKILL.md has no '## Step 3 —' section"

iso_count=$(printf '%s\n' "$STEP3" | grep -cF 'isolation: "worktree"' || true)
[ "$iso_count" -ge 2 ] \
  || fail "Step 3 names 'isolation: \"worktree\"' $iso_count time(s); expected at least 2 (phase-1 AND phase-2 spawn blocks)"

grep -qF 'Agent(subagent_type: general-purpose, model: <tier>, run in background,' "$SKILL_MD" \
  || fail "the phase-1 spawn block's opening line moved or was reworded — check it still carries isolation: \"worktree\""

# Gotchas names the cwd-inheritance hazard, so the next reader doesn't rediscover it cold.
GOTCHAS=$(awk '/^## Gotchas /{flag=1} flag' "$SKILL_MD")
[ -n "$GOTCHAS" ] || fail "skills/auto-dev/SKILL.md has no '## Gotchas' section"
printf '%s\n' "$GOTCHAS" | grep -qi "inherit" \
  || fail "Gotchas does not name the cwd-inheritance hazard (#412)"
printf '%s\n' "$GOTCHAS" | grep -qi "cwd\|working directory" \
  || fail "Gotchas does not mention the supervisor's cwd/working directory being inherited"

# --- Task 2: the worker commands say the given worktree IS the worktree ----------------------
for f in "$WORKER_MD" "$MERGE_MD"; do
  grep -qi "worktree you were given\|given worktree" "$f" \
    || fail "$f does not state that the given worktree is the one to work in"
  grep -qi "make-worktree\.sh" "$f" \
    || fail "$f does not warn against calling make-worktree.sh for another worktree"
  grep -qi "never touch\|do not touch\|outside your own\|outside its own\|outside the worktree" "$f" \
    || fail "$f does not forbid touching a path outside its own worktree"
done

echo "PASS: auto-dev-dispatch"
