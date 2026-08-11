# GitHub / git mechanics for `merge-pr`

The fiddly `gh`/`git`/`jq`/GraphQL snippets the main workflow leans on. Read the section you need when
you hit it. `{owner}/{repo}` is a literal `gh` placeholder it resolves from `origin` (the repo the
profile names) — paste it as-is. And `git <commit-identity>` is the author line from the profile's
*Commit identity* (SKILL.md Step 1) — substitute its `-c user.email=… -c user.name="…"` flags below.

---

## 1. Resolve the PR number from whatever the user gave you

A bare number, a PR/issue URL, or a `gh` link all reduce to the first run of digits:

```bash
ARG="$1"   # e.g. 279 | https://github.com/<owner>/<repo>/pull/279 | "#279"
PR=$(printf '%s' "$ARG" | grep -oE '[0-9]+' | head -1)
```

Strip any `--follow-up "…"` args before this so their text can't contribute stray digits — parse the
command into the PR token and the list of follow-up strings first, then run the digit extraction on the
PR token alone.

Confirm it's a real, open PR before doing anything irreversible:

```bash
gh pr view "$PR" --json number,title,state,isDraft,mergeStateStatus,headRefName,baseRefName,url \
  --jq '"\(.number) [\(.state)\(if .isDraft then "/draft" else "" end)] \(.mergeStateStatus) \(.headRefName) — \(.title)"'
```

---

## 2. Find — or create — the branch's worktree

Corrections must land in a checkout of the PR's head branch. List worktrees and match the branch:

```bash
HEAD_BRANCH=$(gh pr view "$PR" --json headRefName --jq .headRefName)

# Print "<path> <branch>" per worktree, then grep the branch.
git worktree list --porcelain \
  | awk '/^worktree /{p=$2} /^branch /{sub("refs/heads/","",$2); print p, $2}' \
  | grep -E " ${HEAD_BRANCH}$"
```

If a worktree is found, `cd` to its path and `git pull --ff-only` so it's current. If not, and Step 4
shows corrections are needed, create one tracking the remote branch (prefer
`superpowers:using-git-worktrees`; this is the manual fallback):

```bash
git fetch origin "$HEAD_BRANCH"

# Establish the precondition BEFORE creating anything. `$KIT` is the kit root (the directory holding
# skills/ and scripts/); the guard judges the repo at -C, so it works from an installed plugin.
"$KIT/scripts/worktrees-ignored.sh" -C "$REPO"   # 0 ok · 1 a worktree home is not ignored · 2 rule broadened

WT=".claude/worktrees/merge-$PR"               # ignored — asserted just above, not assumed
git worktree add "$WT" "$HEAD_BRANCH"          # checks out the existing branch (tracks origin/$HEAD_BRANCH)
cd "$WT"
```

**Why the check comes first.** `.claude/worktrees/` is this kit's convention, and a convention is not
a fact about *someone else's* repository. A worktree is a full checkout, so where the rule is absent
the next `git add -A` stages it — measured shape (#43): one `160000 <sha> 0 .claude/worktrees/<branch>`
gitlink pointing at a commit no clone can fetch, not a large diff anyone notices in review. This file
used to state the guarantee as settled ("the repo's conventional (git-ignored) home") while nothing
established it; the line above is what makes it true rather than hopeful.

On a **non-zero** exit, do not create the worktree:

- **`1`** — a worktree home is not ignored. Say so and propose the one-line `.gitignore` addition the
  guard names. **Never edit a consumer's `.gitignore` silently**: it is their repository, the change
  belongs in their history under their review, and an agent quietly rewriting ignore rules to unblock
  itself is a worse failure than the one being prevented. With their go-ahead, add it and re-run.
- **`2`** — the rule was broadened over `.claude/skills/repo-profile.md`, which `get-repo-profile`
  expects them to commit. Surface it; do not "fix" it by narrowing their rule unasked.
- **`3`** — plumbing (not a repo, bad arguments). A verdict was never reached, so it is not a pass.

Remember the exact path — Step 7 removes it.

---

## 3. Waiting on CI

The authority is the **check-runs on the PR's head SHA**, not `gh pr checks` — the latter can print a
phantom `skipped` check-run alongside the real one for the same job (a known GitHub Actions behavior
when a draft-gated job re-triggers), so its verdict can't be trusted directly:

```bash
SHA=$(gh pr view "$PR" --json headRefOid --jq .headRefOid)
# --slurp piped to a separate jq (gh's --jq can't combine with --slurp) flattens every page's
# {total_count, check_runs:[...]} into one list — safe even if check-runs ever exceed a page.
runs=$(gh api "repos/{owner}/{repo}/commits/$SHA/check-runs" --paginate --slurp \
         | jq '[.[].check_runs[] | {name, state: (.conclusion // .status)}]')

failed=$(printf '%s' "$runs"  | jq '[.[] | select(.state=="failure" or .state=="cancelled" or .state=="timed_out" or .state=="action_required")]')
pending=$(printf '%s' "$runs" | jq '[.[] | select(.state=="queued" or .state=="in_progress")]')
```

Merge is permitted (CI-wise) when `failed` is empty **and** `pending` is empty **and** the PR is not a
draft — not when one named job reports `success`. A `skipped` check-run is neither `failed` nor
`pending`, so it's simply not evidence of anything; treating it as a blanket "CI didn't run" hangs
forever when a workflow path filter legitimately skips a job the PR's files don't touch (see
`SKILL.md` Step 3 for the full three-way breakdown of why a check reads `skipped`).

Inspect failures via the rollup (gives the log URL to read):

```bash
gh pr view "$PR" --json statusCheckRollup \
  --jq '.statusCheckRollup[] | select(.conclusion=="FAILURE") | {name, detailsUrl}'
```

- **`runs` is empty** (no check-runs at all) → the PR has no CI; treat CI as satisfied and let
  `mergeStateStatus` (§4) be the only gate.
- **Long pipelines** → re-poll the check-runs recipe rather than busy-looping. If you'd rather not hold
  the turn open, come back later (e.g. via `ScheduleWakeup`).
- `gh pr checks "$PR" --watch` is still useful as a **human-facing** progress view in a terminal, but
  don't wire its exit code or printed verdict into the gate — re-derive from the check-runs recipe above.

The repo's CI gates (so you can reproduce a red check locally) are the profile's *CI gates* — its build,
test, and format/lint **verify** commands, plus any prerequisite the profile flags (a workload, a
toolchain). The format/lint gate trips on style/analyzer diffs that compile fine; run the profile's
format/lint **apply** command, then its **verify** command to confirm it's clean. Heed the profile's
caveats — some analyzer diagnostics can't be auto-fixed and must be hand-corrected.

---

## 4. Sync with `main` and resolve conflicts (`BEHIND` / `DIRTY`)

Clears the `BEHIND`/`DIRTY` merge states in the corrections loop (SKILL.md Step 4): merge the latest
base into the branch and resolve conflicts so the PR is mergeable again, then loop back to wait for CI
(§3).

The procedure — merge-not-rebase, the union/regenerate/take-the-higher rule-of-thumb keyed off the
profile's *Conflict hot-spots* table, and finish-and-verify — is shared with `implement-issue` and
lives in [`../../_shared/sync-with-main.md`](../../_shared/sync-with-main.md). Never push a merge you
haven't at least built.

Its writes are guarded, so pass `$BRANCH`, `$WORKTREE`, `$GUARDS` and `$BASE` (SKILL.md Step 2)
through to it. Two things bite here specifically:

- **`$BASE` is `baseRefName`, not `main`.** Step 1 captures it because a PR's base is only *normally*
  `main`. Sync from the wrong one and the PR stays `BEHIND` no matter how many times this loop runs.
- **Exit 5 from `guarded-merge.sh` means conflicts — keep going, don't re-run.** It is the expected
  outcome of a `DIRTY` sync, not an error: resolve, then complete the merge with
  `guarded-commit.sh … -- --no-edit`. Re-running the merge instead gets refused (exit 2), because the
  index still carries the unfinished one.

---

## 5. Unresolved review threads (`CHANGES_REQUESTED` / open conversations)

The overall decision:

```bash
gh pr view "$PR" --json reviewDecision --jq .reviewDecision   # APPROVED | CHANGES_REQUESTED | REVIEW_REQUIRED | null
```

Inline review comments (REST — quick read of what reviewers said and where):

```bash
gh api "repos/{owner}/{repo}/pulls/$PR/comments" --paginate \
  --jq '.[] | {path, line, user:.user.login, body}'
```

Unresolved **threads** need GraphQL (REST doesn't expose `isResolved`):

```bash
gh api graphql -f query='
  query($owner:String!,$repo:String!,$pr:Int!){
    repository(owner:$owner,name:$repo){
      pullRequest(number:$pr){
        reviewThreads(first:100){
          nodes{ id isResolved isOutdated
            comments(first:1){ nodes{ path body author{login} } } } } } } }' \
  -F owner='{owner}' -F repo='{repo}' -F pr="$PR" \
  --jq '.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved==false) | {id, path:.comments.nodes[0].path, body:.comments.nodes[0].body}'
```

Fix the legitimate asks in the worktree, commit + push (project identity). Then either reply to the
thread explaining the fix, or resolve it once addressed (`THREAD_ID` from the query above):

```bash
gh api graphql -f query='
  mutation($id:ID!){ resolveReviewThread(input:{threadId:$id}){ thread{ isResolved } } }' \
  -F id="$THREAD_ID"
```

For a comment you disagree with, **reply on the thread** with your reasoning rather than silently
ignoring it (`superpowers:receiving-code-review` discipline). The goal is to flip `reviewDecision` off
`CHANGES_REQUESTED` honestly. A required-approvals block you can't self-clear is a genuine
blocker — surface it.

---

## 6. Discovering follow-ups in the PR

Two sources beyond the inline `--follow-up` args:

**PR body** — look for a deferred-work section:

```bash
gh pr view "$PR" --json body --jq .body \
  | grep -iA12 -E '^#+ *(follow[ -]?ups?|deferred|out[ -]of[ -]scope|future work)'
```

**Review comments that defer work** — phrases that explicitly punt to a later change:

```bash
gh api "repos/{owner}/{repo}/pulls/$PR/comments" --paginate --jq '.[].body' \
  | grep -iE 'follow[ -]?up|separate (pr|issue)|in a (later|future) (pr|change)|out of scope|TODO.*(later|future)'
```

Only treat as a follow-up something **explicitly flagged as deferred** — not every `// TODO` in the
diff. De-dup against the inline args (don't file the same idea twice), then hand each distinct idea to
the `create-issue` skill, noting the source PR for traceability.

---

## 7. Teardown — remove the worktree and local branch

You can't remove a worktree or delete a branch you're standing in, so the move depends on **where** the
PR's branch is checked out. Decide the case from §2's worktree listing.

### Case A — the PR's branch is in a *different* worktree (the usual case)

Move to the main checkout, remove the PR's worktree, then delete its local branch:

```bash
MAIN=$(git worktree list --porcelain | awk '/^worktree /{print $2; exit}')   # first entry = primary working tree
cd "$MAIN"

# Remove the PR's worktree (force only if it has dirty/untracked leftovers — a merged PR shouldn't).
git worktree remove "$PR_WORKTREE_PATH" 2>/dev/null || git worktree remove --force "$PR_WORKTREE_PATH" 2>/dev/null || true
git worktree prune

# Delete the local branch. -D (not -d): after a squash-merge the branch isn't "merged" in git's view,
# so -d refuses. Tolerate "not found" — gh pr merge --delete-branch may already have removed it.
git branch -D "$HEAD_BRANCH" 2>/dev/null || true
```

### Case B — the PR's branch is checked out in *this session's own* worktree

This happens when `/merge-pr` is invoked from inside the very worktree that holds the PR branch.
**Don't remove this worktree** — it's the session's live workspace, not a throwaway, and git won't let
you delete a directory you're standing in anyway. The disposable thing is the *branch*. So switch this
worktree off it (back to its prior branch, or detach), then delete the merged branch:

```bash
# A native ExitWorktree/equivalent is the harness-aware way to leave the current worktree — prefer it.
# Manual fallback: switch off the merged branch, then delete it.
git -C "$THIS_WORKTREE" switch "$PRIOR_BRANCH" 2>/dev/null || git -C "$THIS_WORKTREE" switch --detach
git -C "$THIS_WORKTREE" branch -D "$HEAD_BRANCH" 2>/dev/null || true
```

Tip: if the branch was *created* in this worktree this session (no meaningful prior branch), detaching
is cleanest. Re-fetching `origin/main` and switching to a fresh branch off it is also fine if you need
the post-merge tree (e.g. to keep working).

### Both cases

Guards matter — this step runs after the irreversible merge, so it must never *fail the run* just
because something was already cleaned up. "Already gone" is success. The **remote** branch is already
gone via Step 5's `--delete-branch`; gh leaves the **local** side untouched when the branch is checked
out in a worktree (you'll see `failed to delete local branch … used by worktree` or `'main' is already
used by worktree`), which is exactly why this step exists.

**Safety:** never remove `$MAIN` or a worktree whose branch isn't the PR's head. Match the path to the
branch (via §2's listing) before removing — a wrong `git worktree remove --force` throws away someone
else's in-progress work.

---

## 8. Troubleshooting (error → cause → solution)

| Error | Cause | Solution |
|---|---|---|
| `Failed to connect to github.com port 443` on `git push`/`fetch` while `gh` works | Sandbox blocks raw git network traffic (not an outage — `gh` proves the host is reachable) | Re-run just that command with the sandbox disabled; local git (merge, commit, worktree remove, branch -D) needs no network |
| `failed to delete local branch … used by worktree` after the merge | `gh pr merge --delete-branch` can't touch a branch checked out in a worktree | Expected — that's what Step 7 handles: remove the worktree, then `git branch -D` |
| `git branch -d` refuses: "not fully merged" | After a squash-merge the branch isn't "merged" by git's reckoning | Use `-D` (force) — the squash commit on `main` carries the work |
| `mergeable=UNKNOWN` right after `main` moved | GitHub is recomputing the merge state | Not a blocker — re-poll shortly; nudge a main-sync only if it persists |
| Commands act on the wrong checkout | A `cd` in a compound command gets reset between tool calls | Use `git -C <path>` / absolute paths — especially the teardown, which must run against `$MAIN`, not the worktree being deleted |
| `guarded-merge: CONFLICTS on <branch>` (exit 5) | **Not an error** — the expected outcome of a `DIRTY` sync. HEAD is still your branch and the conflicts are in the working tree | Resolve per the rule-of-thumb (§4), then **complete** the merge: `guarded-commit.sh … -- --no-edit`. To walk away instead, `guarded-merge.sh … -- --abort` |
| `guarded-merge: REFUSED — the index … already carries an UNRESOLVED merge` (exit 2) | A previous sync stopped at exit 5 and was never finished; git refuses a second merge on an unmerged index (its own exit 128) | **Nothing merged.** Finish the one in flight (resolve + `guarded-commit … -- --no-edit`) or abandon it (`-- --abort`), then sync again |
| `guarded-commit.sh: No such file or directory` in the corrections loop | `$GUARDS`/`$WORKTREE`/`$BRANCH` were never recorded — Step 2 deferred the worktree and Step 4 created one without setting them | Record all four names (Step 2's block) at the point the worktree appears, then re-run the correction |
| `guarded-*: REFUSED — HEAD is on 'X' but this task owns 'Y'` (exit 2) | Prevention working: the corrections are being run from the wrong checkout | **Nothing was written.** Move to the PR branch's own worktree (§2) and retry — never "just commit anyway" |
