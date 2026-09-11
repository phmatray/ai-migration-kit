#!/usr/bin/env bash
# Golden test for skills/implement-issue/scripts/finish-task.sh (#499): one call closes a task —
# commit through guarded-commit.sh, tick that task's boxes through tick-plan.sh, mirror them on
# the PR body, push through guarded-push.sh — in that order, with the refusal paths of the guards
# it composes still refusing.
#
# Real git (a bare remote + a clone), a `gh` stub on PATH that stores what it is sent and serves
# it back, so tick-plan.sh's read-back and the PR mirror are exercised rather than assumed.
set -euo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$KIT_ROOT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT_ROOT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT_ROOT"
WORK=$(kit_scratch)
FINISH="$KIT_ROOT/skills/implement-issue/scripts/finish-task.sh"
fail() { echo "FAIL [$1]: $2"; exit 1; }

# --- the gh stub: an issue store, a PR store, a call log ------------------------------------------
export GH_ISSUE="$WORK/issue.md" GH_PR="$WORK/pr.md" GH_LOG="$WORK/gh.log"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$*" in
  *"-X PATCH"*)
    f=""; prev=""; for a in "$@"; do [ "$prev" = "--input" ] && f="$a"; prev="$a"; done
    jq -r .body < "$f" > "$GH_ISSUE"; exit 0 ;;
  "api repos/"*"--jq .body")   cat "$GH_ISSUE" ;;
  "pr view"*)                  cat "$GH_PR" ;;
  "pr edit"*)
    f=""; prev=""; for a in "$@"; do [ "$prev" = "--body-file" ] && f="$a"; prev="$a"; done
    cp "$f" "$GH_PR" ;;
  *) echo "stub: unexpected gh $*" >&2; exit 9 ;;
esac
STUB
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"

cat > "$GH_ISSUE" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: the first slice

- [ ] **Step 1:** Write the failing test.
- [ ] **Step 2:** Make it pass.
- [ ] **Step 3:** Commit: `feat(x): first slice`

### Task 2: the second slice

- [ ] **Step 1:** Write the failing test.
- [ ] **Step 2:** Commit: `feat(x): second slice`
PLAN
printf 'Closes #42.\n\n### Plan\n- [ ] Task 1: the first slice\n- [ ] Task 2: the second slice\n' > "$GH_PR"

# --- real git: a bare remote and a clone on the task's branch --------------------------------------
git init -q --bare "$WORK/remote.git"
git -C "$WORK" clone -q "$WORK/remote.git" wt 2>/dev/null
WT="$WORK/wt"
git -C "$WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$WT" push -q origin HEAD:main 2>/dev/null
git -C "$WT" checkout -q -b fix/42
git -C "$WT" push -q -u origin fix/42 2>/dev/null
printf 'work\n' > "$WT/a.txt"

# ---------------------------------------------------------------------------------------------
echo "== 1. one call: commit, tick task 1 on the issue AND the PR, push =="
out=$("$FINISH" --repo o/r --issue 42 --task 1 --pr 7 --worktree "$WT" --branch fix/42 -c user.email=t@t -c user.name=t 2>&1) \
  || fail happy "expected exit 0, got $? — $out"
msg=$(git -C "$WT" log -1 --format=%s)
[ "$msg" = "feat(x): first slice" ] || fail happy-msg "commit message should come from Task 1's last step, got '$msg'"
[ "$(git -C "$WT" rev-parse HEAD)" = "$(git -C "$WORK/remote.git" rev-parse fix/42)" ] || fail happy-push "remote fix/42 is not HEAD"
[ "$(grep -c '^- \[x\]' "$GH_ISSUE")" -eq 3 ] || fail happy-tick "issue: expected 3 ticked boxes, got $(grep -c '^- \[x\]' "$GH_ISSUE")"
grep -q '^- \[ \] \*\*Step 1:\*\* Write the failing test.$' "$GH_ISSUE" || fail happy-scope "Task 2's boxes must stay unticked on the issue"
grep -q '^- \[x\] Task 1: the first slice$' "$GH_PR" || fail happy-mirror "PR mirror: Task 1 line not ticked"
grep -q '^- \[ \] Task 2: the second slice$' "$GH_PR" || fail happy-mirror-scope "PR mirror: Task 2 line must stay unticked"
grep -q '^Closes #42' "$GH_PR" || fail happy-mirror-head "the PR body's head was lost in the mirror"
echo "  ok: committed '$msg', 3 boxes ticked on the issue, Task 1 line ticked on the PR, remote == HEAD, Task 2 untouched"

echo "== 2. re-run is idempotent: nothing recommitted, nothing re-ticked, exit 0 =="
before=$(git -C "$WT" rev-parse HEAD)
out=$("$FINISH" --repo o/r --issue 42 --task 1 --pr 7 --worktree "$WT" --branch fix/42 2>&1) || fail idem "expected exit 0, got $? — $out"
[ "$(git -C "$WT" rev-parse HEAD)" = "$before" ] || fail idem-commit "a second run created a commit"
printf '%s' "$out" | grep -q 'already committed' || fail idem-say "should say already committed: $out"
printf '%s' "$out" | grep -q 'already ticked'    || fail idem-tick "should say already ticked: $out"
echo "  ok: already committed, already ticked, no second write"

echo "== 3. a task the plan does not have: exit 65, nothing written anywhere =="
printf 'more\n' > "$WT/b.txt"
: > "$GH_LOG"; before=$(git -C "$WT" rev-parse HEAD)
rc=0; out=$("$FINISH" --repo o/r --issue 42 --task 9 --worktree "$WT" --branch fix/42 2>&1) || rc=$?
[ "$rc" -eq 65 ] || fail absent "expected exit 65, got $rc — $out"
[ "$(git -C "$WT" rev-parse HEAD)" = "$before" ] || fail absent-commit "a missing task still produced a commit"
grep -q 'PATCH\|pr edit' "$GH_LOG" && fail absent-write "a missing task still wrote to GitHub"
echo "  ok: refused by name, no commit, no write"

echo "== 4. the worktree is on another branch: guarded-commit refuses (2) BEFORE any tick =="
git -C "$WT" checkout -q -b elsewhere
: > "$GH_LOG"
rc=0; out=$("$FINISH" --repo o/r --issue 42 --task 2 --worktree "$WT" --branch fix/42 2>&1) || rc=$?
[ "$rc" -eq 2 ] || fail branch "expected guarded-commit's exit 2, got $rc — $out"
printf '%s' "$out" | grep -q '^finish-task: commit:' || fail branch-name "the failing stage must be named: $out"
grep -q 'PATCH' "$GH_LOG" && fail branch-order "the tick ran although the commit was refused"
grep -q '^- \[ \] \*\*Step 2:\*\* Commit: `feat(x): second slice`' "$GH_ISSUE" || fail branch-tick "Task 2 was ticked without a commit"
echo "  ok: commit refused, stage named, tick never ran"

echo "== 5. --dry-run writes nothing and names every stage =="
git -C "$WT" checkout -q fix/42
: > "$GH_LOG"
out=$("$FINISH" --repo o/r --issue 42 --task 2 --pr 7 --worktree "$WT" --branch fix/42 --dry-run 2>&1) || fail dry "expected exit 0, got $? — $out"
printf '%s' "$out" | grep -q 'would commit' && printf '%s' "$out" | grep -q 'would flip 2 box' && printf '%s' "$out" | grep -q 'would push' \
  || fail dry-say "dry-run must name the three stages: $out"
grep -q 'PATCH\|pr edit' "$GH_LOG" && fail dry-write "dry-run wrote to GitHub"
porcelain=$(git -C "$WT" status --porcelain)
grep -q 'b.txt' <<<"$porcelain" || fail dry-commit "dry-run committed the tree"
echo "  ok: three stages named, nothing written"

echo "finish-task golden test: all cases behaved as specified"
