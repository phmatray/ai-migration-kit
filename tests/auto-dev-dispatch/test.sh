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
#
# Reads only files under skills/auto-dev/ — never samples/ — so no kit_guard is needed.
set -euo pipefail
cd "$(dirname "$0")/../.."
KIT="$PWD"

. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"

fail() { echo "FAIL: $1"; exit 1; }

SKILL_MD="$KIT/skills/auto-dev/SKILL.md"
[ -f "$SKILL_MD" ] || fail "missing $SKILL_MD"

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

echo "PASS: auto-dev-dispatch"
