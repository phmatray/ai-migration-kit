#!/usr/bin/env bash
# Golden test for make-worktree.sh — implement-issue's Step 4, driven to red first (#280).
#
# The incident this pins: a phase-1 worker composed its own worktree-ignore check instead of
# calling the kit's, got a false "NOT ignored" verdict (git check-ignore -q without the trailing
# slash, on a directory that does not exist yet), and "fixed" it by committing a .gitignore edit
# into the MAIN checkout — e0ad515, 2026-08-27, docs/desktop-launcher. Every case below drives
# make-worktree.sh over a scratch repository shaped like one side of that incident.
set -euo pipefail
cd "$(dirname "$0")/../.."

HELPER="./skills/implement-issue/scripts/make-worktree.sh"
[ -x "$HELPER" ] || { echo "FAIL: $HELPER missing or not executable"; exit 1; }
KIT="$PWD"

. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"
WORK=$(kit_scratch)

# A throwaway repo on `main`, whose .gitignore is exactly $2 — make-worktree.sh always creates
# fresh off `main`, so every fixture needs one to branch from.
init_repo() {
  local dir="$1" gitignore="$2"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name "Golden Test"
  printf '%b' "$gitignore" > "$dir/.gitignore"
  git -C "$dir" add -A
  git -C "$dir" commit -qm base
}

# ---------------------------------------------------------------- 1. refusal: home not ignored
#
# The state of a repo that never adopted #43's rule at all — neither worktree home is mentioned,
# so worktrees-ignored.sh's `1` fires on both. The exact spelling of the incident's OWN mistake
# (a worker's hand-rolled `check-ignore` without the trailing slash) is covered by case 2 below;
# this case is the simpler, more common way a repo can be unprotected in the first place.

caseA="$WORK/case-a"
init_repo "$caseA" 'unrelated.txt\n'
BRANCH_A="feat/1-unignored-home"

cp "$caseA/.gitignore" "$WORK/case-a.gitignore.before"
commits_before=$(git -C "$caseA" rev-list --count HEAD)

rc=0
out=$("$KIT/$HELPER" -C "$caseA" "$BRANCH_A" 2>&1) || rc=$?
[ "$rc" -eq 2 ] || { echo "FAIL [unignored-home]: expected exit 2, got $rc"; echo "$out"; exit 1; }

cmp -s "$caseA/.gitignore" "$WORK/case-a.gitignore.before" \
  || { echo "FAIL [unignored-home]: .gitignore was modified — this script must NEVER write it"; exit 1; }

commits_after=$(git -C "$caseA" rev-list --count HEAD)
[ "$commits_before" = "$commits_after" ] \
  || { echo "FAIL [unignored-home]: a commit landed in the main checkout ($commits_before -> $commits_after)"; exit 1; }

[ ! -e "$caseA/.claude/worktrees/$BRANCH_A" ] \
  || { echo "FAIL [unignored-home]: a worktree directory was left on disk despite the refusal"; exit 1; }

wt_count=$(git -C "$caseA" worktree list --porcelain | grep -c '^worktree ')
[ "$wt_count" -eq 1 ] \
  || { echo "FAIL [unignored-home]: git worktree list grew to $wt_count entries despite the refusal"; exit 1; }

echo "  ok: unignored-home — exit 2, .gitignore byte-identical, no new commit, no worktree left behind"

# ---------------------------------------------------------------- 2. the incident's exact spelling
#
# .gitignore DOES carry `.claude/worktrees/` and `.worktrees/` — both anchored, trailing-slash,
# exactly as this kit's own .gitignore does — but NEITHER directory exists yet, which is the state
# of every fresh checkout and the exact state Step 4 is in before it creates anything. A guard
# spelled `check-ignore -q .worktrees` (no slash) answers "NOT ignored" here; the real
# worktrees-ignored.sh answers "ignored", because it queries with the slash. This case proves that
# false negative cannot come back through this script.

caseB="$WORK/case-b"
init_repo "$caseB" '.claude/worktrees/\n.worktrees/\n'
BRANCH_B="feat/2-incident-spelling"

[ ! -e "$caseB/.claude/worktrees" ] \
  || { echo "FAIL [incident-spelling]: fixture setup bug — .claude/worktrees/ already exists"; exit 1; }

rc=0
out=$("$KIT/$HELPER" -C "$caseB" "$BRANCH_B") || rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL [incident-spelling]: expected exit 0, got $rc"; echo "$out"; exit 1; }

printf '%s\n' "$out" | grep -q '^WORKTREE=' \
  || { echo "FAIL [incident-spelling]: no WORKTREE= line in output:"; echo "$out"; exit 1; }
printf '%s\n' "$out" | grep -qF "BRANCH=$BRANCH_B" \
  || { echo "FAIL [incident-spelling]: no BRANCH=$BRANCH_B line in output:"; echo "$out"; exit 1; }

wt_path=$(printf '%s\n' "$out" | sed -n 's/^WORKTREE=//p')
[ -d "$wt_path" ] \
  || { echo "FAIL [incident-spelling]: WORKTREE= path does not exist on disk: $wt_path"; exit 1; }
git -C "$wt_path" symbolic-ref --quiet --short HEAD | grep -qF "$BRANCH_B" \
  || { echo "FAIL [incident-spelling]: $wt_path is not checked out on $BRANCH_B"; exit 1; }

echo "  ok: incident-spelling — the correctly-slashed rule passes before the directory exists, exit 0"

echo "implement-issue-worktree-step golden test OK"
