# Before creating a worktree: prove its home is ignored

Shared by `implement-issue` (Step 4) and `merge-pr` (Steps 2 and 4). One home for the verdicts,
because the first draft of this check spelled them out in four places and they had already drifted
apart by the time anyone read two of them.

## Why

`.claude/worktrees/` is **this kit's convention, not a fact about the repository you are pointed at**.
A worktree is a full checkout, so where the rule is missing the next `git add -A` stages it — and the
measured shape (#43, git 2.50.1) is a single gitlink:

```
160000 <sha> 0  .claude/worktrees/<branch>
```

not a large diff anyone notices in review, and pointing at a commit no clone can fetch (there is no
submodule URL and no remote). `git` prints `warning: adding embedded git repository`, and on a busy
console that warning is the only thing between this and a silent commit.

`superpowers:using-git-worktrees` states the precondition — *"MUST verify directory is ignored before
creating worktree"* — and `implement-issue` Step 4 delegates creation to it. This is that verification,
made mechanical.

## The check

Run it against the **worktree root** of the repo you are about to create a worktree in:

```bash
REPO_ROOT=$(git -C <repo> rev-parse --show-toplevel)
<kit>/scripts/worktrees-ignored.sh -C "$REPO_ROOT"
```

`<kit>` is the kit root — the directory holding `skills/` and `scripts/` — resolved when the skill
loads, the same placeholder `legacy-upgrade` and `followups` use for `<kit>/scripts/…`. Do **not**
write it as a shell variable: an unset `$KIT` expands to `/scripts/worktrees-ignored.sh`, i.e. exit
`127`, and a caller that treats every non-zero as "stop" then refuses to create any worktree at all.

**The root matters.** `.claude/worktrees/` contains a slash, so git anchors it and resolves it relative
to the directory it is asked about. Point the guard at a subdirectory and a correctly configured repo
answers "NOT ignored".

## The verdicts

| Exit | Meaning | What to do |
|---:|---|---|
| `0` | both worktree homes are ignored | Create the worktree. |
| `1` | **a worktree home is NOT ignored** | Do not create it. Surface the one-line `.gitignore` addition the guard names, and let the owner take it. |
| `2` | homes are ignored, but the rule is broad enough to hide `.claude/skills/repo-profile.md` | **Create the worktree — there is no worktree hazard here.** Mention that this repo cannot carry a committed profile until the rule is narrowed. |
| `3` | usage error, or not a git repository | No verdict was reached. That is not a pass — fix the invocation. |
| `126`/`127` | the guard is missing or not executable | Same: no verdict. Check `<kit>` resolved. |

⚠️ **`2` is a different finding, not a worse one.** Collapsing this to "anything non-zero → stop" is
the tempting shortcut and it is wrong: a repo whose `.gitignore` holds `.claude/` and `.worktrees/`
has *both* homes covered and zero #43 risk, yet exits `2`. Refusing it would deny service over a
condition unrelated to the hazard being guarded.

## If the kit's `scripts/` is not there

`get-repo-profile` documents a skills-only adoption path ("drop the four skills into a new repo"), and
the guard lives at the kit root, so it can legitimately be absent. That is a missing *tool*, not a
failed *verdict* — don't refuse the worktree over it. Check both homes by hand instead, from the
worktree root:

```bash
git -C "$REPO_ROOT" check-ignore -q .claude/worktrees/ && git -C "$REPO_ROOT" check-ignore -q .worktrees/
```

The trailing slashes and `-q` are both load-bearing: a directory-only pattern does not match a
non-existent path spelled without the slash, and `-v` exits `0` merely because *some* pattern matched
— including a negation, which means the path is **not** ignored.

## Never edit the repository's `.gitignore` unasked

On `1`, propose the line; do not add it yourself. It is someone else's repository, the change belongs
in their history under their review, and an agent quietly rewriting ignore rules to unblock itself is
a worse failure than the one being prevented. With their go-ahead, add it and re-run.

## What a `0` does and does not prove

`git check-ignore` is satisfied by `.git/info/exclude` and by `core.excludesFile`, both **machine-local**.
The path really is ignored for whoever runs the guard — so the immediate hazard is covered and `0` is
correct — but the repository carries no such rule, and every teammate's and CI's `git add -A` still
stages the worktree. The guard prints a `note:` naming that case. Do not promote a `0` carrying such a
note into a durable claim about the repo (`get-repo-profile` records exactly that, so it repeats the
note rather than the verdict alone).
