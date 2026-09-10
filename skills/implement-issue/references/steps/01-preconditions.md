## Step 1 — Preconditions

**Follow the shared preconditions reference** at [`../_shared/preconditions.md`](../../../_shared/preconditions.md)
to load the repo profile, verify authentication, and prepare the commit identity shorthand.

Throughout this skill, **`<commit-identity>`** stands for the author line from the profile's *Commit
identity* — `-c user.email=<email> -c user.name="<name>"`. Substitute it in every commit/merge
command. In the guarded calls of Steps 5–9 it goes **before** the branch name
(`guarded-commit.sh -C "$WORKTREE" <commit-identity> "$BRANCH" -- …`), which is where the script
forwards it to `git` itself; passed
after `--` it would reach `git commit -c`, which means "reuse this commit's message" and which git
refuses to combine with `-m`.

Then, resolve the **issue number** from the user's request — a number (`21`), an issue URL, or a link
to the plan comment (`…/issues/21#issuecomment-12345`). The locator snippets in
`references/github-mechanics.md` handle all three.
