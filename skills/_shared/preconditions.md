# Shared Preconditions: Profile Load, Auth, & Commit Identity

This reference is used by every lifecycle skill to establish preconditions at Step 1. Each skill
links here and adds only its skill-specific extras.

## Load the repo profile

The repo profile is the single source of truth for repo-specific facts — commit identity, labels, CI
gates, conflict hot-spots, architecture grain. It lives, committed, at
**`.claude/skills/repo-profile.md`**; read it through the helper that already knows how to say it is
not there:

```bash
<kit>/skills/profile-repo/scripts/repo-profile.sh show
```

`<kit>` is the kit root — the directory holding `skills/` and `scripts/` — resolved when the skill
loads, the same placeholder [`worktree-ignore-check.md`](./worktree-ignore-check.md) and
`migrate-legacy` use. Do **not** write it as a shell variable: an unset `$KIT` expands to
`/skills/…`, i.e. exit `127`, which is a missing tool being read as a verdict.

The helper takes an optional directory and otherwise anchors itself to the repo root, so it resolves
from any subdirectory — and from a linked worktree, where the profile is present because it is
tracked.

### The outcomes

| Exit | Output | What it means | What to do |
|---:|---|---|---|
| `0` | the profile | it is committed and readable | Use it. Every repo-specific value below comes from it. |
| `3` | `NO_PROFILE` | this repository has **no committed profile** | Run **`profile-repo`** to generate one, then re-read. |
| `2` | `ERR: cannot cd …` | the directory argument is wrong | No verdict was reached — fix the invocation, don't read it as "no profile". |
| `126`/`127` | shell error | the helper is missing or not executable | Also **no verdict** — check that `<kit>` resolved. `profile-repo` documents a skills-only adoption path, so the script can legitimately be absent; open `.claude/skills/repo-profile.md` yourself in that case, and treat an unreadable one as `NO_PROFILE` below. |

Only `0` and `3` are **verdicts**. The rest mean the question was never answered — and "no verdict" is
not "no profile", which is the whole distinction this call exists to preserve.

**Why not just read the file.** A bare `cat` of a missing profile writes one line to *stderr*, nothing
to stdout, and returns a status nobody reads — so "this repo has no profile" and "this repo's profile
is silent" look identical, and the skill proceeds to infer the commit identity, the CI gates and the
label set from the repository instead. That inference is usually right, which is exactly what makes it
dangerous: it is invisible in the successful case (#157). `show` turns the same situation into a named
condition with a named remedy.

**`NO_PROFILE` is informative, not fatal.** A repository may legitimately not carry one — a first run,
or a team that has chosen not to commit it. Generating one is the remedy; if that is genuinely
impossible, **say so in the report, name the values you had to infer and where you got them**, and
carry on. Do not stop the run over it, and do not infer silently.

## Verify authentication

Check that your `gh` authentication works and you're targeting the correct repo:

```bash
gh api user --jq .login                                  # prints a login, or 401 → not authed
gh repo view --json nameWithOwner --jq .nameWithOwner    # confirm it's the repo the profile names
```

If the auth check fails with a 401 error, stop and tell the user to run this in the prompt:

```bash
! gh auth login -h github.com
```

The `!` prefix runs the command in the current session, so the token lands in your environment. Then
re-check the `gh api user` command before continuing.

If the profile's **Tracker** line (or, with no profile, the host of `git remote get-url origin`) is
not GitHub, stop with one sentence — *the lifecycle skills drive GitHub semantics through `gh`;
`<host>` is not a supported tracker* — and do not infer a substitute.

## Commit identity shorthand

Throughout the skill's commands, **`git <commit-identity>`** is a shorthand that expands to the
author line from the profile's *Commit identity* section. It looks like:

```bash
git -c user.email=<email> -c user.name="<name>"
```

Substitute it in every commit/merge/rebase command. Example:

```bash
git <commit-identity> commit -m "message here"
```

In the issue/PR lifecycle skills those writes go through the guards rather than through bare `git`,
and there the flags travel **without** the leading `git` and **before** the branch name — that is
where the script forwards them to `git` itself:

```bash
"$GUARDS/guarded-commit.sh" -C "$WORKTREE" <commit-identity> "$BRANCH" -- -m "message here"
"$GUARDS/guarded-merge.sh"  -C "$WORKTREE" <commit-identity> "$BRANCH" -- origin/main
```

This ensures commits are authored with the canonical identity (usually GitHub, not work email).

---

**Each lifecycle skill's Step 1 links to this file and adds only its own required profile sections.**

## Consumers

- `skills/create-issue/SKILL.md` — Step 1 loads the repo profile and verifies authentication
- `skills/deliver-issue/SKILL.md` — Step 1 loads the repo profile and verifies authentication
- `skills/implement-issue/SKILL.md` — Step 1 loads the repo profile, verifies authentication, and prepares the commit-identity shorthand
- `skills/merge-pr/SKILL.md` — Step 1 loads the repo profile, verifies authentication, and prepares the commit-identity shorthand
- `skills/review-sessions/SKILL.md` — Step 1 loads the repo profile (the *ADRs* root and the *Identity* slug feed later steps)
- `skills/triage-backlog/SKILL.md` — Step 1 loads the repo profile, verifies authentication, and prepares the commit-identity shorthand
