---
name: merge-pr
description: >-
  Land an open GitHub pull request the way a careful maintainer would — the "ship it" counterpart
  to `implement-issue`. Use whenever the user wants to MERGE, land, ship, or close out an open PR:
  waits for CI, then applies corrections until mergeable — fixes red checks, merges the latest
  `main` and resolves conflicts, addresses unresolved review — squash-merges, triages follow-up work
  (inline `--follow-up "…"` args plus ones discovered in the PR) by folding symptoms into the root
  issue that owns them and filing the rest via `create-issue`, and tears down the branch and
  worktree. Triggers: "merge PR 279", "land #281", "ship this PR", "get that PR merged once CI's
  green", "wrap up 279 and open follow-ups", « merge la PR 279 », « fais
  atterrir la 281 », or a bare PR link with "merge it". Does NOT apply to opening or implementing a
  PR, to syncing one still being built (implement-issue), to reviewing without merging
  (code-review), or to filing a standalone issue (create-issue).
license: MIT
compatibility: >-
  Requires an authenticated gh CLI with merge/push rights, and git. Files follow-ups via the
  create-issue skill. Reads the committed repo profile (.claude/skills/repo-profile.md) generated
  by get-repo-profile.
metadata:
  author: Philippe Matray
  suite: ai-migration-kit
---

# Merge a pull request

## What this does

`implement-issue` builds a PR and flips it to ready. This skill is the final step: it **lands** that PR
cleanly and cleans up after itself. The job isn't just `gh pr merge` — a PR that's ready isn't
necessarily *mergeable* minutes later, because `main` moves, CI runs, and reviewers leave comments. So
this skill closes the gap: waits for CI, fixes whatever is actually blocking the merge, squashes the PR
in, turns deferred work into tracked issues, and removes the throwaway branch and worktree.

The shape mirrors `implement-issue`'s tail (sync-with-`main`, the profile's conflict hot-spots, the
commit identity) — reuse that machinery. The one new piece is the **corrections loop**: keep clearing
blockers and re-waiting until GitHub reports the PR `CLEAN`, then merge.

## Autonomy contract

Run **hands-off** once started — the user points at a PR and walks away. Whenever a step *could* stop
for a question, pick the reasonable default, state the assumption, keep going. Stop only for a genuine
blocker:

- `gh` not authenticated, or no merge/push rights.
- The PR doesn't exist, is already merged/closed, or the number is ambiguous.
- **CI stays red after a real fix attempt.** Don't merge over a red bar, don't disable a failing test, don't `--admin`-override a required check. Fix it for real or stop and show the failing output.
- **A merge conflict you can't resolve with confidence** — both `main` and the branch rewrote the *same logic*. The mechanical conflicts (version, changelog, snapshots, lockfiles) have known-correct fixes (Step 4) — handle those; stop only for genuinely ambiguous ones, showing both sides.
- **A reviewer requested changes you can't satisfy** without guessing intent, or a branch-protection rule you can't legitimately clear (required approvals you can't self-give).

The merge is the irreversible act — earn it. Merge only when CI is **green on the just-corrected
branch** and GitHub reports the PR mergeable; a textual merge of `main` is not a semantic one, so
re-build/re-test after resolving conflicts. Filing a follow-up and deleting a local branch are
reversible — but a follow-up is cheap to *file* and expensive to *carry*, which is why Step 6 triages
before it files.

## Inputs

- **PR identifier** (required) — a number (`279`), an issue/PR URL, or a `gh` PR link. Resolve to a number (Step 1).
- **`--follow-up "<idea>"`** (optional, repeatable) — follow-up work to file as issues after the merge, e.g. `/merge-pr 279 --follow-up "add Rust snapshot tests" --follow-up "document minimap config"`. *Added to* whatever Step 6 discovers in the PR itself.

## Checklist

Create a task per item and work them in order. Step 4 is a loop — repeat until the PR is mergeable.

1. **Preconditions & resolve the PR** — `gh` works, you're in the target repo, normalize the PR number, confirm it's open, capture its head branch + merge state.
2. **Locate (or create) the branch's worktree** — find the local worktree/branch for the PR's head so corrections land in the right checkout; create one tracking the remote branch if none exists.
3. **Wait for CI** — let the checks finish; read the rollup.
4. **Apply corrections (loop)** — clear each blocker the merge state reports (red CI · behind/dirty vs `main` · unresolved review · draft), push, re-wait until the PR is `CLEAN`.
5. **Merge (squash)** — `gh pr merge --squash --delete-branch` once green and mergeable.
6. **Triage follow-ups** — gather inline `--follow-up` args + ones discovered in the PR, cluster them by root cause, fold instances into the issue that already owns them, and file at most 3 new issues via `create-issue`.
7. **Delete the local branch & worktree** — from the main checkout, remove the PR's worktree and local branch.
8. **Report** — merged PR URL, corrections applied, follow-ups filed, cleanup done.

Resume-safe: re-running mid-flight is fine. If the PR is already merged, skip to Steps 6–7. If the
worktree/branch is already gone, skip Step 7.

---

## Step 1 — Preconditions & resolve the PR

**Follow the shared preconditions reference** at [`../_shared/preconditions.md`](../_shared/preconditions.md)
to load the repo profile, verify authentication, and prepare the commit identity shorthand.

Throughout this skill, **`<commit-identity>`** stands for the author line from the profile's
*Commit identity* — `-c user.email=<email> -c user.name="<name>"`. Substitute it in every
commit/merge command. In the guarded calls of Step 4 it goes **before** the branch name
(`guarded-commit.sh -C "$WORKTREE" <commit-identity> "$BRANCH" -- …`), which is where the script
forwards it to `git` itself; after `--` it would reach the subcommand, whose own `-c` means something
else entirely.

Normalize the PR identifier to a number (bare number, issue/PR URL, and `gh` link all reduce to the
first run of digits — see `references/merge-mechanics.md` §1), then confirm it's real and open and
capture what drives the rest of the run:

```bash
gh pr view "$PR" --json number,title,state,isDraft,mergeable,mergeStateStatus,reviewDecision,headRefName,baseRefName,url \
  --jq '{number,title,state,isDraft,mergeable,mergeStateStatus,reviewDecision,head:.headRefName,base:.baseRefName,url}'
```

- `state != OPEN` → if `MERGED`, skip to Steps 6–7 (follow-ups + cleanup); if `CLOSED` (not merged), stop and ask — merging a deliberately closed PR is not a safe default.
- `isDraft == true` → the user asked to *merge* it, so the flag is almost always stale. Mark ready (`gh pr ready "$PR"`), note the assumption, continue. (If genuinely unfinished, the CI/corrections loop surfaces it.)
- Capture **`headRefName`** (branch) and **`baseRefName`** (normally `main`) — Steps 2, 4, 7 key off the branch name.

## Step 2 — Locate (or create) the branch's worktree

Corrections (Step 4) edit code, so they must land in a checkout of the PR's **head branch** — not
whatever worktree you're in now. Find it:

```bash
git worktree list --porcelain        # match the entry whose branch == headRefName
```

- **A worktree for the branch exists** (usual case — `implement-issue` left one): use it. Pull first: `git -C <path> pull --ff-only`.
- **No local worktree/branch** (PR built elsewhere, or already cleaned): create one **only if** Step 4 needs corrections. If the PR is already `CLEAN` with green CI, merge without checking out locally. When needed, create an isolated worktree tracking the remote branch via `superpowers:using-git-worktrees` (or `git worktree add <path> <branch>` as fallback — reference §2). Remember the path; Step 7 removes it.

**As soon as you know a worktree will be involved — whether you found one above or will create one
here or in Step 4 — prove its home is ignored, before touching it.** This repo is not the kit's, and
`.claude/worktrees/` is the kit's convention, not a fact about someone else's checkout. Run the check
from [`../_shared/worktree-ignore-check.md`](../_shared/worktree-ignore-check.md); it takes no
worktree path, so the same call serves the found worktree and the one not yet created.

`0` go ahead · `1` a home is **not** ignored, so stop before pulling into it or creating one · `2`
ignored but over-broad, so **do** go ahead and mention the profile cost · `3`/`127` no verdict, which
is not a pass. Full verdict table, the bare-repository case, why `2` is not a stop, and the
never-edit-their-`.gitignore` rule are all in that one file. Skipping this is how #43 reproduces in a
customer repo — silently, as a single gitlink rather than a diff anyone spots.

⚠️ **Reuse is the usual case here, so the check cannot hang off creation** (#86) — but it still runs
*before* the worktree is touched, not after. The bullet above calls an existing worktree the normal
outcome, and a guard that only fired on `git worktree add` would skip precisely those repos; one that
fired after the `pull --ff-only` below would be writing into the unignored home it was about to
refuse. **No worktree, no check** stays true — a PR that is already `CLEAN` merges without a local
checkout and has nothing to verify.

Don't run corrections from the current session's worktree if it isn't the PR's branch — you'd edit the
wrong checkout (a known footgun here). Use `git -C <path>` rather than `cd` (a `cd` in a compound
command gets reset between calls). Raw `git fetch`/`git push` may be sandbox-blocked even though `gh`
works (a `port 443` timeout) — re-run just those with the sandbox disabled; local git needs no network.
See `references/merge-mechanics.md` §8.

**The moment a worktree is in hand — here, or later in Step 4 if this step deferred creating one —**
record the four names Step 4's guarded writes need. Same convention `implement-issue` Step 4 defines,
so the shared main-sync procedure reads the same variables from either skill:

```bash
BRANCH=<headRefName from Step 1>
WORKTREE=<absolute path of that branch's worktree>
GUARDS=<the kit's skills/implement-issue/scripts directory>
BASE=<baseRefName from Step 1>     # NOT assumed to be main — plenty of repos default to dev
```

The ignore check above is a **precondition of this block**, not part of it: it has already run by the
time `$WORKTREE` has a value, which is why its recipe never asks for one.

Record them at whichever point the worktree appears: this step skips creation when the PR looks
`CLEAN`, and Step 4 then creates one only if corrections turn out to be needed. Reaching a guarded
command with these unset is not a soft failure — `"$GUARDS/guarded-commit.sh"` expands to
`/guarded-commit.sh`, i.e. "No such file or directory".

Every write in Step 4 passes `"$BRANCH"` and `-C "$WORKTREE"` **explicitly**. "Edited the wrong
checkout" is exactly the failure this skill already warns about; a guard that derived the branch from
`HEAD` would read the very value under suspicion and agree with itself either way.

## Step 3 — Wait for CI

Let the checks finish before judging — a half-run pipeline tells you nothing. The **authority** is the
check-runs on the PR's head SHA, not `gh pr checks` — GitHub can surface a *phantom* `skipped`
check-run alongside the real one for the same job (a known GitHub Actions behavior when a draft-gated
job re-triggers), so don't act on its verdict directly. **Run the check-runs recipe from
`references/merge-mechanics.md` §3**: it collects every check-run on the head SHA (paginated) and
derives two sets — `failed` (failure / cancelled / timed_out / action_required) and `pending`
(queued / in_progress).

While `pending` is non-empty, wait (re-poll, or come back later via `ScheduleWakeup` rather than
busy-looping) — then judge:

- **`runs` is empty** (no check-runs at all) → the PR has no CI; treat CI as satisfied and let Step 4's
  merge-state be the gate.
- `failed` non-empty → read which and why before reacting; the failure feeds Step 4's correction (below).
- `failed` empty → Step 4 to confirm mergeability (nothing-failed ≠ mergeable; `main` may have moved).

**A `skipped` check-run is not evidence of anything** — it's neither `failed` nor `pending`, so the
recipe above already treats it as a non-event. That's deliberate: `skipped` has three common causes,
and only the gate above tells them apart correctly:

| Why a check reads `skipped` | Safe to merge? | What actually guards it |
|---|---|---|
| A draft PR was flipped to ready and its checks never re-ran | **No** — genuinely untested | The PR being a **draft** — when CI re-triggers on `ready_for_review`, a non-draft PR always has real check-runs for the jobs that were going to run (Step 1 already assumes ready) |
| A phantom `skipped` check-run posted alongside a real one for the same job (GitHub Actions can't retroactively void an already-completed `skipped` run when the job re-triggers) | Yes — the phantom is noise | The *real* check-run for that job also exists and reports its own conclusion |
| A workflow path filter correctly skips a job the PR's files don't touch (e.g. the back-end test job on a front-end-only PR) | Yes — by design, there's nothing for that job to test | Nothing — this is the legitimate case a naive gate hangs on |

So never hard-code "wait for `<job-name> == success`" — that hangs forever on the path-filter case
and reintroduces the same bug the moment another job grows a path filter. Gate on the shape instead:
nothing failed, nothing pending, PR not a draft. Repo-specific CI quirks of this kind belong in the
profile's *CI gates* section — record them there, not in this skill.

`gh pr checks "$PR" --watch` is still fine as a **human-facing convenience** for watching progress in
a terminal, but don't treat its printed verdict as authoritative (the phantom-`skipped` case above) —
re-derive from the check-runs recipe before acting. Failure inspection (rollup + log links) and the
long-pipeline polling pattern are also in reference §3.

## Step 4 — Apply corrections (the loop)

The heart of the skill. Re-read the merge state, clear whatever it reports, push, re-wait — until
GitHub reports `CLEAN`. `mergeStateStatus` is the driver:

⚠️ **If Step 2 deferred the worktree** — the normal outcome when the PR looked `CLEAN` there — this is
where it appears, so run Step 2's ignore check **here, before `git worktree add`**, and then record
its `WORKTREE` block. The check is the same call either way; it takes no worktree path precisely so
that deferring the worktree does not defer the guard past the thing it guards —
[`../_shared/worktree-ignore-check.md`](../_shared/worktree-ignore-check.md). Reading the check in
Step 2 and then obtaining the worktree here is how it ends up never running at all.

```bash
gh pr view "$PR" --json mergeStateStatus,mergeable,reviewDecision \
  --jq '{state:.mergeStateStatus, mergeable, review:.reviewDecision}'
```

| `mergeStateStatus` | What it means | Correction |
|---|---|---|
| `CLEAN` | mergeable, all gates satisfied | Done — go to Step 5. |
| `UNKNOWN` | GitHub still computing | Re-poll after a short wait; don't act on it. |
| `DRAFT` | PR is a draft | `gh pr ready "$PR"` (per Step 1's assumption), re-poll. |
| `BEHIND` | base advanced; branch behind `main` | **Sync with `main`** (below), push, re-wait CI. |
| `DIRTY` | merge conflicts with the base | **Sync with `main`** and resolve conflicts (below). |
| `UNSTABLE` | mergeable, but a check is pending/failing | Pending → wait (Step 3). Failing → **fix the red check** (below). A lone `skipped` check-run does **not** produce `UNSTABLE` — Step 3's recipe already treats `skipped` as a non-event, so landing here means something is genuinely pending or failing. |
| `BLOCKED` | a branch-protection gate is unmet | Usually `reviewDecision == CHANGES_REQUESTED` → **address review** (below). If it's *required approvals* you can't self-give, that's a genuine blocker — surface it. |

**Fix a red CI check.** Reproduce locally in the branch's worktree, fix it for real, commit + push. Run
the profile's *Build & test* and *CI gates* — the same ones CI runs: the **build** for compile errors,
the **single-suite test filter** for the failing suite (the full suite may need a CI-only prerequisite
the profile flags), then the format/lint **apply** then **verify** (verify must exit clean — CI fails
on any diff). Commit with the project identity, push, loop back to Step 3:

```bash
"$GUARDS/guarded-commit.sh" -C "$WORKTREE" <commit-identity> "$BRANCH" \
  -- -am "fix: <what you fixed for CI>" \
  && "$GUARDS/guarded-push.sh" -C "$WORKTREE" "$BRANCH"
```

The guards refuse (exit 2) when `HEAD` is anything but `$BRANCH`, prove afterwards that the commit
landed there (exit 3 if not), and read the remote back to confirm it carries this `HEAD` (exit 4 if
not). This loop can run several times against a moving branch, which is precisely when a bare
`git commit -am` is worth least: a zero exit says what git attempted, not where the work went.

**Sync with `main` (for `BEHIND`/`DIRTY`).** Merge the latest base in and resolve conflicts so the PR
is mergeable again. Follow the shared procedure in
[`../_shared/sync-with-main.md`](../_shared/sync-with-main.md) (merge-not-rebase, the conflict
rule-of-thumb keyed off the profile's *Conflict hot-spots*, and finish-and-verify);
`references/merge-mechanics.md` §4 has the merge-pr framing. A clean *text* merge can still break the
build — re-build/re-test before pushing.

**Address unresolved review (for `CHANGES_REQUESTED` / open threads).** Read the comments and unresolved
threads, implement the real asks in the worktree, commit + push, and reply to / resolve the threads so
the decision flips off `CHANGES_REQUESTED`. GraphQL for listing/resolving threads in
`references/merge-mechanics.md` §5. Triage with `superpowers:receiving-code-review` rigor — fix the
legitimate ones; for any you disagree with, reply on the thread rather than silently ignoring. (This
skill does **not** run a fresh `code-review` pass — `implement-issue` did that before ready; it only
reacts to review already on the PR.)

After any correction, **push and return to Step 3** (CI must re-run). Cap the loop at a few rounds; if
it won't converge to `CLEAN`, stop and report the sticking point. Watch the race: a sibling PR merging
mid-loop can knock this one `BEHIND` again — normal, just re-sync; a re-sync right before merge is the
surest path to a clean landing.

## Step 5 — Merge (squash)

Only once CI is green **and** `mergeStateStatus == CLEAN`. The profile's *Integration style* sets how to
land; for squash-merge (the `(#NNN)` commits on `main`):

```bash
gh pr merge "$PR" --squash --delete-branch \
  --subject "<PR title — already ends in (#issue)> (#$PR)"   # optional; omit to accept gh's default
```

**Prefer omitting `--subject`.** `implement-issue` titled the PR `… (#issue)`, and gh's default squash
subject is that title with `(#PR)` appended — giving the canonical `… (#issue) (#PR)` shape
automatically. If you override it, keep the `(#issue)` or you drop the link to the originating issue.

### The exit code doesn't decide — GitHub's state does

`gh pr merge` does **two unrelated things**: it merges the PR **on GitHub**, then tidies up **locally**
(check the base branch out, delete the merged branch). One exit code covers both, so it can never say
which half failed — and the local half fails on this kit's *normal* layout, not an exotic one.
`implement-issue` gives every issue its own worktree, so `/merge-pr` is usually run from one; gh then
switches to the base branch, the primary checkout already holds it, and git refuses:

```
$ gh pr merge 176 --squash --delete-branch
failed to run git: fatal: 'main' is already used by worktree at '<path>/ai-migration-kit'
```

That merge **landed** — only gh's post-merge `git checkout` failed. Run from the primary checkout
instead and you get the *other* message, `failed to delete local branch … used by worktree` (§8's
long-standing row), because gh only needs to switch branches when you are sitting on the head branch.
Two messages, one rule: **the merge call's exit status is advisory.** Its stderr is worth reporting;
it concludes nothing. Read the PR back, and let *that* decide:

```bash
gh pr view "$PR" --json state,mergedAt,mergeCommit --jq '{state, mergedAt, mergeCommit:.mergeCommit.oid}'
```

| readback | what it means | what to do |
|---|---|---|
| `state == MERGED` | the merge landed, whatever the exit code said | continue to **Step 6**. If the merge call exited non-zero, that was local cleanup gh couldn't finish — Step 7 does it, so report it there, not as a failed merge |
| `state == OPEN` | usually a real rejection the loop didn't catch — **but not on a merge-queue repo**, where a *successful* enqueue exits 0, prints `will be added to the merge queue`, and leaves the PR `OPEN` until the queue lands it | queued → let it land and re-read later. A genuine rejection → do **not** reach for `--admin`; surface it and stop |
| `state == CLOSED` | the PR was closed without merging while the loop ran | Step 1's rule applies — stop and ask. Merging a deliberately closed PR is not a safe default |
| the readback itself fails | inconclusive — it says neither merged nor rejected | re-read a few times; if it still won't answer, **stop and report the merge as unconfirmed.** Do *not* fall through into Step 7 — its teardown is destructive and assumes the merge landed. Re-running the skill later is safe: Step 1 routes an already-`MERGED` PR straight on to Steps 6-7 |

**Don't corroborate with the remote branch.** Whether `--delete-branch` reached the remote side before
the local step failed is exactly what the exit code won't tell you — and on a repo with GitHub's own
`delete_branch_on_merge` enabled (this one has it), the branch disappears either way. A missing remote
branch proves nothing about the merge, and a surviving one disproves nothing. `state` is the only
signal that answers the question.

Local cleanup is Step 7's either way (gh can't delete a branch checked out in a worktree; its **Case
B** is this same collision one step later). Take the `|| git switch --detach` fallback from
`references/merge-mechanics.md` §7 when you get there — the obvious "switch back to `main`" walks
straight into the collision that got you here. §8 of that reference carries the row keyed on the
literal message.

### Multi-issue PRs: keep the changelog honest

On a repo with release automation (e.g. `release-please`), the version bump and CHANGELOG entries
derive from **Conventional Commits on `main`**. A squash-merge collapses the whole PR into a single
commit, so a PR that closes several issues yields exactly one release-notes line and one bump —
under-reporting the work.

When squash-merging a PR that closes **more than one issue**, write the squash-commit **body** with
one Conventional Commit line per distinct change, e.g.:

    fix(export): use invariant culture in CSV number formatting (#91)

    feat(export): stream large report downloads (#58, #77)
    feat(export): add XLSX export alongside CSV (#90)

Verify the resulting release PR lists an entry per line. If the release tooling does not split the
body, prefer not bundling unrelated issues into one squash in the first place.

## Step 6 — Triage follow-ups, then file what earns an issue

Landing a PR often leaves a tail of "not now, but worth doing" work. Gather it from two sources and
**de-duplicate**:

1. **Inline args** — every `--follow-up "<idea>"` passed on the command.
2. **Discovered in the PR** — a `## Follow-ups` / "Deferred" / "Out of scope" section in the PR body, and review comments that explicitly defer work ("let's do X in a separate PR", "follow-up:", "TODO in a future change"). Pull the PR body + review comments and scan (snippets in `references/merge-mechanics.md` §6). Don't manufacture follow-ups from ordinary code comments.

Then **triage before filing**. An issue is a commitment to do work, not a record of an observation,
and the two must not share a channel. Filing costs seconds; resolving costs a PR — so a Step 6 that
files everything it noticed grows the backlog faster than any loop can drain it, and the owner ends
up unable to see which item actually matters.

**6a — Cluster by root cause.** Group the findings by the file or subsystem they land in. Findings
that share one are *instances of a single defect*, not N defects: "the numeric path drops `Format`",
"date item fields still discard the adornment" and "`Mask` is inert on both paths" are one duplicated
render path reported three times. Name the shared cause — that, not the symptom, is the unit of work.

**6b — Look for a root that's already tracked, open *or* just closed.** For each cluster, search for
the issue that already owns the cause — typically a `type:refactor` issue naming the same file
(commands in `references/merge-mechanics.md` §6). Search by **file and subsystem**, not by the
symptom's wording: a root issue and its symptoms share almost no vocabulary, which is exactly why
`create-issue`'s own duplicate check won't surface it. This search has to happen here.

**Include closed issues in that search** — the findings came out of the PR you just merged, so they
land in code a recent fix touched, and that fix closed its issue on the way in. An open-only search
cannot see the ancestor, so the finding files as a sibling and one unfinished job becomes a row per
attempt (`#93 → #166 → #172`). A closed ancestor whose scope still describes the work gets
**reopened**, not re-filed; a genuinely different job in the same code opens with
`Continues #<ancestor>.` in the body.

**6c — Put each cluster to the filing bar, then route it.** The bar — what earns an issue versus what
earns a record — lives at [`../_shared/filing-bar.md`](../_shared/filing-bar.md), shared with
`create-issue` and the `auto-dev` workers so all three inlets file to the same standard. Read it and
apply it per *cluster*, not per symptom; the routing table below is what happens after each cluster
has passed or failed:

| The cluster is | Channel | Why |
|---|---|---|
| an instance of a **root issue that exists** | a `- [ ]` item or comment **on that issue** | the work is already committed to; this sharpens its scope instead of lengthening the queue |
| the same job as a **root that was just closed** | **reopen** that issue with the evidence | a fix that didn't finish the job is one issue still open, not two issues — and the reopen is the honest record of it |
| ≥2 findings sharing a **root not yet tracked** | **one** `create-issue` run for the *root*, citing the instances as evidence | fixing symptoms one by one in code the root refactor deletes is work thrown away twice — once writing it, once resolving its conflict |
| genuinely **independent** deferred work | its own `create-issue` run | this is what the channel is for |
| a cluster that **fails the filing bar** (no consequence, no named instance, nobody asked) | a comment on the merged PR | retrievable later, and costs nothing to ignore — and it earns an issue the day a real instance shows up |

**6d — Budget: at most 3 new issues per merge.** Past that, the tail goes into **one** issue named for
the PR ("Findings from #279") listing the rest, or onto the root from 6b. The cap isn't a quality
judgement — it's the brake that keeps arrivals under the rate work can actually be done. Hitting it
means 6a under-clustered: re-read the findings for the cause they share before filing the overflow.

For each cluster that earns an issue, invoke the **`create-issue` skill** (it seeds the brainstorm →
spec → plan trail and labels it). Mention the just-merged PR for traceability, e.g. *"Follow-up from
#279: add Rust snapshot tests."* Batch several in one `create-issue` run. No follow-ups → skip and
say so.

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
the local branch, or no worktree existed, that's success (guard with `|| true`; reference §7). Never
delete the main checkout or an unrelated worktree — match the path to the PR's branch exactly.

## Step 8 — Report

Short and concrete:
- The merged PR — URL and confirmation it's `MERGED` (with the squash commit sha); the branch it closed.
- **Corrections applied** — one line each: red checks fixed, conflicts resolved (which files, how), review addressed. "None needed — merged clean" is a fine report. A non-zero `gh pr merge` exit whose readback said `MERGED` is **not** a correction and not a failed merge — it is local cleanup gh couldn't do and Step 7 then did, so it belongs in the Cleanup bullet, not reported as an outstanding deferral.
- **Follow-ups** — lead with the tally the filing bar produced (*"7 observations · 2 filed · 1 folded · 1 reopened · 3 recorded"*), then the detail: each new issue's title + URL, each one **folded** into an existing issue (`#N`), each **reopened** ancestor (`#N`), each recorded as a PR comment, or "none." If the 6d budget capped anything, say so and name the overflow issue. The tally is what lets the owner see whether the bar is calibrated — all-filed means it isn't being applied.
- **Scope** — say plainly that the PR's own scope is complete. Findings are discovery, not unfinished business: a merge whose plan is ticked and whose CI is green is *done*, and the follow-up tally above is a separate fact about what was noticed along the way.
- **Cleanup** — worktree removed and local branch deleted (or "already gone").
- Anything assumed, deferred, or unverifiable (e.g. full suite skipped for a missing local prerequisite the profile flags). Keep detail in the PR/issues; the report points there.

---

## Notes on quality

- **The merge is the one irreversible act — gate it hard.** Everything else (follow-up issues, branch deletion) is recoverable. Merge only on green CI **and** a `CLEAN` merge state, never by overriding a failing or required check.
- **Correct, don't paper over.** Fix the red test, resolve the real conflict, address the real review note. Skipping a test, forcing past a check, or hand-stitching a snapshot to clear a conflict all *look* like progress and are worse than stopping.
- **Stay resumable.** Every step keys off live GitHub/git state, so a re-run won't double-merge, double-file, or fail because a branch is already gone.
- **Follow-ups are tracked, not narrated** — deferred work belongs in an issue (via `create-issue`), not buried in the merge report.
- **…but tracked at the root, and rationed.** The failure mode this skill is most likely to cause is not a bad merge, it's a backlog nobody can read: one merge that files a dozen leaf issues, each a symptom of one defect, is a net loss even though every issue is individually accurate. Step 6's triage is the corrective — cluster first, fold into the root second, file last.
