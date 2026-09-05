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
#   3. SKILL.md documents a first-act toplevel assertion (the worker reports `git rev-parse
#      --show-toplevel`; the supervisor refuses a match against its own) and what happens on a
#      refusal — re-dispatch correctly, don't let the worker proceed, don't count it BLOCKED. The
#      decision itself is a marked, extractable shell program (same discipline as
#      tests/pr-existence-guard/test.sh, modeled on it) so this suite proves the exact thing an
#      agent would paste, not a paraphrase of it.
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

# --- Task 3: the toplevel assertion, and what a refusal does --------------------------------
#
# 3a. Prose, scoped to the actual new sections — NOT a whole-file grep. A whole-file grep for
#     common words like "re-dispatch" or "BLOCKED" is satisfied by unrelated pre-existing prose
#     elsewhere in this long document (Step 3's tier-escalation note, Step 4's PARTIAL/BLOCKED
#     handling) regardless of whether the NEW guard section says anything at all, which would let
#     this suite pass even if the new prose were deleted outright.
GUARD_SECTION=$(awk '
  /^### ⛔ Dispatch-time guard — confirm the worker actually got its own worktree/ { flag=1 }
  flag { print }
  /^\*\*Pick each worker.s model from its labels\*\*/ { exit }
' "$SKILL_MD")
[ -n "$GUARD_SECTION" ] \
  || fail "skills/auto-dev/SKILL.md has no '### ⛔ Dispatch-time guard — confirm the worker actually got its own worktree' section"

printf '%s\n' "$GUARD_SECTION" | grep -q "git rev-parse --show-toplevel" \
  || fail "the new guard section does not document the first-act 'git rev-parse --show-toplevel' assertion"
printf '%s\n' "$GUARD_SECTION" | grep -qi "re-dispatch" \
  || fail "the new guard section does not say the supervisor re-dispatches on a refusal"
printf '%s\n' "$GUARD_SECTION" | grep -Eqi "not.{0,40}BLOCKED|never.{0,40}BLOCKED" \
  || fail "the new guard section does not say a same-cwd refusal is NOT counted as a BLOCKED issue"
printf '%s\n' "$GUARD_SECTION" | grep -qi "auto-clean" \
  || fail "the new guard section does not state the auto-clean-only-if-unchanged cleanup nuance for isolation: \"worktree\""
printf '%s\n' "$GUARD_SECTION" | grep -qi "Needs manual sweep" \
  || fail "the new guard section does not point a leftover worker worktree at '## Needs manual sweep'"

# 3a'. The plan also asks Step 4's per-slot handling to say what happens on a refusal — a second,
# separately-scoped location, so a future edit that removes it from ONE of the two homes is caught.
STEP4_INTRO=$(awk '
  /^## Step 4 —/ { flag=1 }
  flag { print }
  /^You.re woken by a worker.s report/ { exit }
' "$SKILL_MD")
[ -n "$STEP4_INTRO" ] || fail "skills/auto-dev/SKILL.md has no '## Step 4 —' section"
printf '%s\n' "$STEP4_INTRO" | grep -qi "re-dispatch" \
  || fail "Step 4's intro does not say the supervisor re-dispatches a worker-toplevel guard refusal"
printf '%s\n' "$STEP4_INTRO" | grep -Eqi "not.{0,40}BLOCKED|never.{0,40}BLOCKED" \
  || fail "Step 4's intro does not say a same-cwd refusal is NOT counted as a BLOCKED issue"

# 3b. The decision itself, extracted and RUN — not just grepped for — same discipline as
#     tests/pr-existence-guard/test.sh.
BEGIN_MARK='# >>> worker-toplevel guard'
END_MARK='# <<< worker-toplevel guard'
n_begin=$(grep -c -F -- "$BEGIN_MARK" "$SKILL_MD" || true)
n_end=$(grep -c -F -- "$END_MARK" "$SKILL_MD" || true)
[ "$n_begin" = "1" ] && [ "$n_end" = "1" ] \
  || fail "skills/auto-dev/SKILL.md must carry EXACTLY ONE marked worker-toplevel guard program (found $n_begin/$n_end)"

PROG="$(kit_scratch)/worker-toplevel-guard.sh"
awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
  index($0, b) { inside = 1 }
  inside       { print }
  inside && index($0, e) { exit }
' "$SKILL_MD" > "$PROG"
[ -s "$PROG" ] || fail "extracted an empty worker-toplevel guard program from $SKILL_MD"

# Matching toplevel — the shared-worktree hazard itself — must be a refusal (non-zero exit).
match_out="$(kit_scratch)/match.out"
if WORKER_TOPLEVEL=/repo SUPERVISOR_TOPLEVEL=/repo bash "$PROG" > "$match_out" 2>&1; then
  fail "the worker-toplevel guard exited 0 on a MATCHING toplevel (should refuse):
$(cat "$match_out" 2>/dev/null)"
fi

# A differing toplevel — the normal isolated case — must proceed (exit 0).
diff_out="$(kit_scratch)/diff.out"
if ! WORKER_TOPLEVEL=/repo/.claude/worktrees/agent-x SUPERVISOR_TOPLEVEL=/repo bash "$PROG" > "$diff_out" 2>&1; then
  fail "the worker-toplevel guard exited non-zero on a DIFFERING toplevel (should proceed):
$(cat "$diff_out" 2>/dev/null)"
fi

echo "PASS: auto-dev-dispatch"
