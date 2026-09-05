#!/usr/bin/env bash
# Golden test for the guard-invocation fallback (#414).
#
# $GUARDS points at this skill's own scripts/ directory, resolved from wherever the kit is
# installed — as an installed plugin that is the plugin cache, outside any worktree an
# auto-dev/implement-issue worker is confined to. Two independent workers in one fleet run hit a
# refusal invoking a guard at that path and each improvised its own recovery. This suite pins the
# one documented recovery skills/_shared/guard-invocation.md now states, and that every site
# defining $GUARDS points at it.
#
# Seam under test: the skill documents as TEXT — a documentation contract, not runtime behaviour
# (a refused invocation path is a host/sandbox policy, not something this suite can reproduce).
set -euo pipefail
cd "$(dirname "$0")/../.."

KIT_ROOT="$(pwd)"
. "$KIT_ROOT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT_ROOT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT_ROOT"
kit_guard kit_guard_samples_unchanged

FAILED=0
note_fail() { echo "FAIL: $1"; FAILED=1; }

DOC="skills/_shared/guard-invocation.md"

# ------------------------------------------------------------ 1. the fallback guidance exists
[ -f "$DOC" ] || { echo "FAIL: $DOC does not exist"; exit 1; }

grep -q -- '_assert-branch\.sh' "$DOC" \
  || note_fail "$DOC does not name _assert-branch.sh — a copy that omits it silently breaks the guard"

grep -qi -- 'delete\|remove' "$DOC" \
  || note_fail "$DOC does not state the cleanup step (delete/remove the scratch directory)"

grep -qi -- 'bare `git commit`\|bare `git push`\|bare `git merge`\|never fall back to a bare' "$DOC" \
  || note_fail "$DOC does not forbid falling back to a bare git commit/push/merge"

grep -qi -- 'report' "$DOC" \
  || note_fail "$DOC does not require reporting the deviation"

grep -qi -- 'make-worktree\.sh' "$DOC" \
  || note_fail "$DOC does not explicitly exclude make-worktree.sh's pre-worktree \$GUARDS usage"

# ------------------------------------------------------------ 2. every GUARDS= site points at it
#
# A `GUARDS=` line that defines the variable must be accompanied — within the next few lines — by
# a pointer to the shared fallback doc, so the next skill that adds a guarded call site cannot
# forget it silently. This mirrors ci-wiring-check.py's own reasoning: a missing pointer looks
# exactly like a skill that already covers the case.
CONTEXT_LINES=6
while IFS=: read -r file line _; do
  [ "$file" = "$DOC" ] && continue
  end=$((line + CONTEXT_LINES))
  if ! sed -n "${line},${end}p" "$file" | grep -q -- 'guard-invocation\.md'; then
    note_fail "$file:$line defines \$GUARDS but does not point at $DOC within $CONTEXT_LINES lines"
  fi
done < <(grep -rn '^GUARDS=' skills/)

# ------------------------------------------------------------ 3. fleet workers get the standing clause
for f in commands/auto-dev-worker.md commands/auto-dev-merge.md; do
  [ -f "$f" ] || { note_fail "$f does not exist"; continue; }
  grep -q -- 'guard-invocation\.md' "$f" \
    || note_fail "$f does not point at $DOC"
  grep -qi -- 'report' "$f" \
    || note_fail "$f does not carry the report-the-deviation requirement"
done

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi
echo "PASS: guard-invocation fallback is documented once and every \$GUARDS site points at it"
