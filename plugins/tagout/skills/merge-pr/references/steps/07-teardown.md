## Step 7 — Delete the local branch & worktree

Clean up the throwaway workspace — the right cleanup depends on **where** the branch is checked out
(you can't remove a worktree, or delete a branch, from inside it):

**Case A — the PR's branch lives in a *different* worktree** (usual: you ran `/merge-pr` from the main
checkout or another worktree). Move to the main checkout, remove the PR's worktree, delete its branch:

```bash
MAIN=$(git worktree list --porcelain | sed -n '1s/^worktree //p')   # the primary working tree
cd "$MAIN"

git worktree remove "<pr-worktree-path>"     # add --force if it has untracked/dirty leftovers
git worktree prune                           # clear any stale administrative entries
git branch -D "<headRefName>"                # -D (force): a squashed branch isn't "merged" by git's reckoning, so -d refuses
```

**Case B — the PR's branch is checked out in *this very session's* worktree.** Do **not** remove the
worktree you're running in. Here the *branch* is disposable, not the directory — switch this worktree
back to its prior branch (or detach), *then* delete the merged feature branch:

```bash
git -C "<this-worktree>" switch "<prior-branch>"   # or: git -C "<this-worktree>" switch --detach
git -C "<this-worktree>" branch -D "<headRefName>"
```

A native `ExitWorktree`/equivalent is the harness-aware way to leave the current worktree — use it in
place of the manual `switch` if you have one.

Either way, make each step tolerant of "already gone" — if Step 5's `--delete-branch` already removed
the local branch, or no worktree existed, that's success (guard with `|| true`; reference §8). Never
delete the main checkout or an unrelated worktree — match the path to the PR's branch exactly.

**Then finish the remote side too** — don't assume Step 5's `--delete-branch` or the repo's
`delete_branch_on_merge` setting already deleted `<headRefName>` on `origin` (#185: when gh's local
delete fails first — the routine case here, since the branch lives in a worktree — it never reaches
the remote delete at all):

```bash
skills/merge-pr/scripts/remote-branch-teardown.sh "<headRefName>" "<owner>/<repo>"
```

Prints `already-gone` or `deleted` and exits 0 either way — both are success. A genuine delete
failure exits 1 with the API error on stderr; report that, don't swallow it (reference §8).
