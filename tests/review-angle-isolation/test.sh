#!/usr/bin/env bash
# Golden test: every review sub-agent the kit dispatches is read-only and isolated (#477).
#
# Measured 2026-09-09 on a fleet run: implement-issue's review step fanned out review angles as
# write-capable forks sharing the worker's live worktree; six edited one tree concurrently and one
# pushed to the PR branch. A prompt cannot constrain a fork that inherited `--fix`, so the constraint
# is structural — the agent type (no Edit/Write) and the isolation option — and this suite pins that
# both are stated at the one dispatch site and repeated in both worker commands.
#
# Three textual invariants:
#   1. skills/implement-issue/SKILL.md carries the marked `review-dispatch` block, naming both the
#      read-only agent type and the isolation option, and the parent-applies rule.
#   2. Step 7 no longer offers `--fix` as a path: "Never `--fix`".
#   3. commands/auto-dev-worker.md and commands/auto-dev-merge.md each carry the standing rule.
#
# Reads only files under skills/implement-issue/ and commands/ — no kit_guard needed.
set -euo pipefail
cd "$(dirname "$0")/../.."
KIT="$PWD"

. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"

fail() { echo "FAIL: $1"; exit 1; }

SKILL_MD="$KIT/skills/implement-issue/SKILL.md"
[ -f "$SKILL_MD" ] || fail "missing $SKILL_MD"

# 1. The marked block exists exactly once, and carries both structural constraints.
[ "$(grep -c '<!-- review-dispatch:start -->' "$SKILL_MD")" -eq 1 ] \
  || fail "skills/implement-issue/SKILL.md must carry exactly one review-dispatch:start marker"
block=$(sed -n '/<!-- review-dispatch:start -->/,/<!-- review-dispatch:end -->/p' "$SKILL_MD")
[ -n "$block" ] || fail "review-dispatch block is empty or unterminated"
grep -qF 'subagent_type: Explore' <<<"$block" \
  || fail "review-dispatch block does not name the read-only agent type (subagent_type: Explore)"
grep -qF 'isolation: "worktree"' <<<"$block" \
  || fail "review-dispatch block does not name isolation: \"worktree\""
grep -qi 'parent applies' <<<"$block" \
  || fail "review-dispatch block does not state that the parent applies the findings"

# 2. Step 7 never offers --fix as the fast path (that instruction is what a fork inherits).
if grep -qF -- '`--fix` is the fast path' "$SKILL_MD"; then
  fail "skills/implement-issue/SKILL.md still offers --fix as the fast path"
fi
grep -qF 'Never `--fix`' "$SKILL_MD" || fail "skills/implement-issue/SKILL.md does not say Never --fix"

# 3. Both worker commands carry the standing rule, with both constraints.
for cmd in auto-dev-worker auto-dev-merge; do
  f="$KIT/commands/$cmd.md"
  [ -f "$f" ] || fail "missing $f"
  grep -qF 'subagent_type: Explore' "$f" || fail "commands/$cmd.md does not name subagent_type: Explore"
  grep -qF 'isolation: "worktree"' "$f" || fail "commands/$cmd.md does not name isolation: \"worktree\""
  grep -qi 'read-only and isolated' "$f" || fail "commands/$cmd.md does not carry the read-only review rule"
done

echo "PASS: review-angle-isolation"
