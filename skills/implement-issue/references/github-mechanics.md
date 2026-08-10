# GitHub mechanics for `implement-issue`

The fiddly, easy-to-get-wrong `gh`/`jq`/`git` snippets the main workflow leans on. Read this when
you hit any of: resolving the issue from a weird input, locating the plan (in the issue body or, on
older issues, a comment), ticking a single task's checkboxes without touching the others, or resuming
onto an existing branch/PR.

Throughout, `{owner}/{repo}` is a literal `gh` placeholder it resolves from the repo's `origin`
(the repo the profile names) — you can paste it as-is. And `<commit-identity>` is shorthand for the
author line from the profile's *Commit identity* (SKILL.md Step 1) — substitute its `-c user.email=… -c
user.name="…"` flags in the commit/merge commands below. In a `guarded-commit.sh` call it goes before
the branch name, not after `--`, since those are options to `git` rather than to `git commit`.

---

## 1. Resolve the issue number from whatever the user gave you

The user may pass a bare number, an issue URL, or a link to the plan comment. Normalize to a number.

```bash
ARG="$1"   # e.g. 21  |  https://github.com/<owner>/<repo>/issues/21
           #          |  https://github.com/<owner>/<repo>/issues/21#issuecomment-3098…
ISSUE=$(printf '%s' "$ARG" | grep -oE '[0-9]+' | head -1)   # first run of digits = issue number
```

If the link is a comment permalink (`#issuecomment-<id>`), you can also pull that comment id
directly and skip the search in §2:

```bash
COMMENT_ID=$(printf '%s' "$ARG" | sed -n 's/.*issuecomment-\([0-9]*\).*/\1/p')   # empty if not a comment link
```

Confirm the issue exists and is the right one before doing anything destructive:

```bash
gh issue view "$ISSUE" --json number,title,state --jq '"\(.number) [\(.state)] \(.title)"'
```

---

## 2. Locate the plan (issue body first, comment fallback)

`create-issue` writes the plan into the **issue body**, so look there first — and when the plan lives
in the body, you tick boxes by PATCHing the issue itself (§4), no comment id needed. Only fall back to
the comment trail for issues filed by older versions.

```bash
# Preferred: the plan is in the description. Fetch to a PRISTINE copy, check it, then work on a
# duplicate — §4 needs the untouched original both to validate the write and to restore from.
gh api "repos/{owner}/{repo}/issues/$ISSUE" --jq .body > /tmp/plan-$ISSUE.orig.md
[ -s /tmp/plan-$ISSUE.orig.md ] || { echo "empty fetch for #$ISSUE — do NOT write anything back"; exit 1; }
cp /tmp/plan-$ISSUE.orig.md /tmp/plan-$ISSUE.md

if grep -q '🛠️ Implementation plan' /tmp/plan-$ISSUE.md; then
  PLAN_SRC=body
else
  PLAN_SRC=comment
fi
```

⚠️ **The `[ -s ]` check is load-bearing, not decoration.** A failed or rate-limited fetch leaves an
empty file, and every downstream step happily turns that into a valid empty body — which is exactly
how two live issue bodies were destroyed. Never edit-and-write a plan file you have not proved was
fetched.

When `PLAN_SRC=comment`, you need the comment's **numeric REST id** (the database id) — that's what
the PATCH endpoint in §4 edits. `gh issue view --json comments` returns GraphQL **node ids** (`IC_kw…`),
which the REST PATCH rejects. Always go through the REST comments endpoint:

```bash
if [ "$PLAN_SRC" = comment ]; then
  # All comments, newest-relevant plan comment wins. The marker is the bold header create-issue posted.
  # --slurp piped to a separate jq (gh's --jq can't combine with --slurp) flattens every page's
  # array into one list before `last` picks the actual latest match — `--paginate --jq` alone runs
  # the filter independently per page and concatenates the results, so `last` only sees whichever
  # page happens to print after the others.
  PLAN_COMMENT_ID=$(gh api "repos/{owner}/{repo}/issues/$ISSUE/comments" --paginate --slurp \
    | jq -r '[.[][] | select(.body | contains("🛠️ Implementation plan"))] | last | .id')

  # Fallback if no marker (older/hand-written plan): latest comment that has checkbox lines.
  if [ -z "$PLAN_COMMENT_ID" ]; then
    PLAN_COMMENT_ID=$(gh api "repos/{owner}/{repo}/issues/$ISSUE/comments" --paginate --slurp \
      | jq -r '[.[][] | select(.body | (contains("- [ ]") or contains("- [x]")))] | last | .id')
  fi

  # Nothing in the body AND nothing in comments? Stop — there is no plan to execute (Autonomy contract).
  [ -z "$PLAN_COMMENT_ID" ] && { echo "No implementation plan on #$ISSUE"; exit 1; }

  # Pull the comment body to the same working files (pristine original + working copy).
  gh api "repos/{owner}/{repo}/issues/comments/$PLAN_COMMENT_ID" --jq .body > /tmp/plan-$ISSUE.orig.md
  [ -s /tmp/plan-$ISSUE.orig.md ] || { echo "empty fetch for comment $PLAN_COMMENT_ID — write nothing back"; exit 1; }
  cp /tmp/plan-$ISSUE.orig.md /tmp/plan-$ISSUE.md
fi
```

`--paginate` matters: a busy issue can have >30 comments and the plan may not be on page one. And it
must be `--paginate --slurp` piped to a separate `jq`, not `--paginate --jq` — `gh api`'s `--jq` runs
its filter independently *per page* and concatenates the results rather than merging pages first, so a
`last | .id` filter picks the last match on whichever page happens to print last, not the true latest
match across the whole comment history; `--slurp` (which can't combine with `--jq`) flattens every
page into one array before `jq` sees it. Either way `/tmp/plan-$ISSUE.md` now holds the plan
text; a body-sourced file also carries the template fields and collapsed brainstorm/spec above it,
which is fine — §3/§4 only ever touch `### Task` checkbox lines.

---

## 3. Decide which tasks are already done (resume + progress)

A task is **done** when every checkbox in its block is ticked. Quick whole-comment progress:

```bash
done=$(grep -c '^- \[x\]' /tmp/plan-$ISSUE.md)
todo=$(grep -c '^- \[ \]' /tmp/plan-$ISSUE.md)
echo "$done done / $((done+todo)) steps"
[ "$todo" -eq 0 ] && echo "All tasks already complete."
```

To find the first unchecked task, scan `### Task` headings and look for the first block that still
contains a `- [ ]` line. Implement from there; skip blocks that are all `- [x]`.

---

## 4. Tick one task's checkboxes — precisely

**Never** `sed -i 's/\[ \]/[x]/g'` the whole file — that ticks unfinished tasks too and turns the
issue's progress board into a lie. Flip only the lines belonging to the task you just committed.

Preferred: edit `/tmp/plan-$ISSUE.md` line by line with the **Edit tool**, changing each of
that task's `- [ ] **Step k:** …` lines to `- [x] **Step k:** …`. The step text is unique, so each
Edit targets exactly one line and fails loudly if something drifted — which is the safety you want.

Then write the whole body back — the **issue** when the plan lives in its description, or the
**comment** on a legacy issue — **through `tick-plan.sh`**:

```bash
if [ "$PLAN_SRC" = body ]; then
  ./skills/implement-issue/scripts/tick-plan.sh \
    --repo {owner}/{repo} --issue "$ISSUE" \
    --before /tmp/plan-$ISSUE.orig.md --after /tmp/plan-$ISSUE.md
else
  ./skills/implement-issue/scripts/tick-plan.sh \
    --repo {owner}/{repo} --issue "$ISSUE" --comment-id "$PLAN_COMMENT_ID" \
    --before /tmp/plan-$ISSUE.orig.md --after /tmp/plan-$ISSUE.md
fi
```

It wraps the file with `jq -Rs` (a JSON string, so backticks, quotes and newlines survive intact)
and PATCHes with `--input -`, which is far more robust than `-f body=...` for large, Markdown-heavy
bodies. The body-sourced file holds the *whole* description, so flipping only this task's checkbox
lines leaves the template fields and brainstorm/spec untouched. After the write, the issue re-renders
with this task's boxes ticked — and because the plan is in the body, the progress meter advances too.
The script then re-reads the issue and asserts the stored body matches what it sent.

### ⛔ Never pipe `jq` straight into a mutating `gh api`

The recipe this replaced —

```bash
jq -Rs '{body: .}' /tmp/plan-$ISSUE.md | gh api ".../issues/$ISSUE" -X PATCH --input -   # DESTROYED TWO ISSUES
```

— wiped the full body of two live issues in a single unattended run, silently, exiting `0`. The
mechanism is worth knowing because the obvious fix does not work:

| plan file | `jq` exit | what `jq` prints | pipeline exit |
|---|---|---|---|
| missing | 2 | `{"body": ""}` — **well-formed, not empty output** | **0** |
| empty | **0** | `{"body": ""}` | **0** |

`jq -Rs` slurps *nothing* into the empty string and faithfully builds a valid payload, so `gh` is
never handed anything malformed to reject. And because `jq` exits **0** on the empty-file path,
**`set -o pipefail` does not catch it** — the reflex fix closes only the top row of that table.

There is no guard on the *transport* that helps; the **body** has to be checked. `tick-plan.sh`
does it exactly rather than heuristically: ticking is a one-character substitution, so with every
box normalised back to `[ ]` the new body must be **byte-identical** to the old one. Missing, empty,
truncated, rewritten, un-ticked or no-op bodies all fail that test, and none of them reach GitHub.
Covered by `tests/tick-plan/test.sh` in CI.

**The PR description's mirror list** gets the same treatment — flip *this task's* `- [ ] Task N: …`
line in the PR's `### Plan` list, then write it back:

```bash
gh pr view $PR_NUMBER --json body --jq .body > /tmp/pr-$ISSUE.md
[ -s /tmp/pr-$ISSUE.md ] || { echo "empty PR body fetch — do NOT write it back"; exit 1; }
# Edit-tool per line: flip only this task's "- [ ] Task N:" line to "- [x] Task N:".
[ -s /tmp/pr-$ISSUE.md ] && gh pr edit $PR_NUMBER --body-file /tmp/pr-$ISSUE.md
```

⚠️ **`gh pr edit --body-file` on an empty file blanks the PR description** — the same defect as §4's
issue PATCH, one endpoint over. It is less costly (the PR list is a mirror; the issue is canonical)
but it is the same mistake, so it gets the same `[ -s ]` guard on both the read and the write.

Re-fetch isn't needed within a single run — you own the source and hold the canonical copy in the
temp file. (If you ever suspect a concurrent edit, re-fetch, re-apply your flips, re-PATCH.)

---

## 5. Worktree, branch, draft PR — and reusing them on resume

Branch naming ties the worktree, branch, and PR to the issue:

```bash
SLUG=$(gh issue view "$ISSUE" --json title --jq .title \
  | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' | cut -c1-40)
BRANCH="feat/$ISSUE-$SLUG"
```

Before creating anything, check whether a prior run already set things up (resume). Match on
**`$BRANCH`** — this issue's own name. "Am I already in a worktree?" is the wrong question and the
one that produced the incident in Step 4: being in *someone else's* worktree passes it.

```bash
git worktree list | grep -F "$BRANCH"                    # THIS issue's worktree already present?
gh pr list --head "$BRANCH" --json number,url,isDraft --jq '.[0]'   # PR already open?
```

If they exist, work in that worktree (with `git -C`) and reuse the PR — don't open a second one.
Otherwise create the worktree via `superpowers:using-git-worktrees`, then the draft PR (empty
scaffold commit so the branch is ahead of `main`):

```bash
./skills/implement-issue/scripts/guarded-commit.sh <commit-identity> "$BRANCH" \
  -- --allow-empty -m "chore(#$ISSUE): scaffold draft PR"
./skills/implement-issue/scripts/guarded-push.sh "$BRANCH" -- -u origin "$BRANCH"
gh pr create --draft --base main --head "$BRANCH" \
  --title "<type>(<scope>): <subject> (#$ISSUE)" --body "<body, Closes #$ISSUE>"
# Title follows the profile's PR-title convention (commonly a Conventional Commits prefix plus a
# (#issue) suffix). Never pass the issue title through verbatim.
```

The guards take `$BRANCH` explicitly and refuse (exit 2) if HEAD is anything else; `guarded-push.sh`
additionally reads the remote back and exits 4 if it does not carry this HEAD. Both are local-only
apart from that one ref read, and both run from any working directory via `-C <repo>`.

---

## 6. Mark ready (only after green)

```bash
gh pr ready "$PR_NUMBER"          # number from `gh pr create`, or `gh pr list --head "$BRANCH"`
```

`gh pr ready` with no extra flag flips draft → ready-for-review. There's no separate "approve" — the
human reviewer takes it from there.

---

## 7. Sync with `main` and resolve conflicts (before the ready-flip)

Issues run in parallel and `main` advances while the PR sits in draft, so it drifts out of
mergeability. Before the ready-flip, merge the latest `main` into the branch, resolve conflicts, and
re-verify on the merged tree.

The procedure itself — merge-not-rebase, the union/regenerate/take-the-higher rule-of-thumb keyed off
the profile's *Conflict hot-spots* table, and the finish-and-verify step — is shared with `merge-pr`
and lives in [`../../_shared/sync-with-main.md`](../../_shared/sync-with-main.md). Follow it, then
continue to Step 9 (full build/tests + format gate) — never push a merge you haven't at least built.

---

## Gotchas, collected

- **Body first, comment fallback.** `create-issue` writes the plan into the issue **body** now, so
  `PLAN_SRC=body` is the normal path and you PATCH the issue (`.../issues/$ISSUE`). The comment path
  is only for issues filed by older versions. Ticking a body plan also advances the progress meter,
  which a comment plan never did.
- **Node id vs REST id (comment path only).** `gh issue view --json comments` → GraphQL `IC_kw…` ids;
  the PATCH endpoint needs the **numeric** id from `gh api .../comments`. Mixing them up is the #1 way
  the comment tick fails. Irrelevant when the plan is in the body.
- **Pagination (comment path only).** Always `--paginate` the comments call; the plan comment may be
  past comment 30.
- **The emoji marker is the anchor.** `create-issue` writes `## 🛠️ Implementation plan` (older issues:
  a `**🛠️ Implementation plan**` comment). Match on the `🛠️ Implementation plan` substring; keep the
  §2 checkbox fallback for hand-written plans.
- **`jq -Rs` for the body — inside `tick-plan.sh`, never in a bare pipe.** Hand-building the JSON
  (or `-f body=`) mangles plans full of backticks, code fences, and `<` `>`; `jq -Rs '{body:.}'` is
  lossless. But it is lossless about *whatever it was given*, including nothing — piping it straight
  into a mutating `gh api` is what destroyed two issue bodies (§4).
- **Keep the pristine fetch.** `/tmp/plan-$ISSUE.orig.md` is never edited. Without an untouched copy
  there is nothing to validate the new body against and nothing to restore from.
- **Whole-file sed is forbidden.** Tick per task, not per repo — see §4.
- **Reconcile the mirror on resume.** The issue PATCH and the PR-body edit aren't atomic; a crash
  between them leaves the PR's `### Plan` line unticked forever unless the next run re-syncs it
  from the issue state (the canonical source) before entering the loop.
- **Empty commit is intentional.** It exists only so a draft PR can open before any code lands; the
  first real task commit immediately makes it meaningful. Don't squash it away mid-run.
- **Sync before ready — merge, not rebase.** The full procedure (and the why) is in
  [`../../_shared/sync-with-main.md`](../../_shared/sync-with-main.md), summarized at §7; the one thing
  to remember here is that a clean text merge can still be a broken compile, so re-build after resolving.
- **Use `git -C <path>` rather than `cd <path> && …`** — a `cd` in a compound command gets reset
  between calls here.

---

## Troubleshooting (error → cause → solution)

| Error | Cause | Solution |
|---|---|---|
| `404 Not Found` on the comment PATCH | A GraphQL node id (`IC_kw…`) was used where the endpoint needs the **numeric REST id** | Re-fetch the id via the REST comments endpoint (§2), re-PATCH |
| `Failed to connect to github.com port 443` on `git push`/`fetch` while `gh` works | Sandbox blocks raw git network traffic (not an outage — `gh` proves the host is reachable) | Re-run just that command with the sandbox disabled; local git (merge, commit, worktree) needs no network |
| "No implementation plan on #N" | The issue carries no plan in its body or comments | Stop (Autonomy contract) — nothing to execute; seed a plan via `create-issue` if the user insists |
| PATCH succeeded but the progress meter didn't move | The plan lives in a comment (meter counts body checkboxes only), or the wrong task's lines were flipped | Verify which source was PATCHed (§2's `PLAN_SRC`); re-flip with the Edit tool per line (§4) |
| `tick-plan: REFUSED — body length changed` / `differs outside the checkboxes` | Something rewrote the working file beyond flipping boxes (a stray Edit, a re-fetch mid-task, an agent "tidying" the body) | **Nothing was sent — the issue is intact.** Re-copy `/tmp/plan-$ISSUE.orig.md` over the working file, re-apply only this task's flips, re-run |
| `tick-plan: REFUSED — --after file is empty` / `does not exist` | The fetch failed, or the working file was clobbered. This is the wipe (Koine#1813) being caught | **Nothing was sent.** Re-fetch via §2 and restart the tick; never hand-PATCH around the script |
| `tick-plan: REFUSED — no checkbox was ticked` | The per-line Edit didn't land (step text drifted from what the plan actually says) | Re-read the working file, match the real step text, re-flip. A no-op write would look like progress |
| A commit landed on **another branch** (and a push carried it into someone else's PR) | A concurrent checkout switched HEAD in a shared working tree between the branch creation and the commit. `git commit` never re-checks the branch, so it exits 0 | Cherry-pick the commit onto the branch it belongs to, then `git revert` it on the branch it wrongly landed on. **Never force-push a branch you do not own** — its author may already have built on it. Then move to this issue's own worktree (Step 4) and route every write through the guards |
| `guarded-commit: REFUSED — HEAD is on 'X' but this task owns 'Y'` (exit 2) | Prevention working: something checked out `X` in this worktree | **Nothing was committed.** Check out `Y` — better, move to `Y`'s own worktree — and re-run. Do not "just commit anyway" |
| `guarded-commit: ALERT — the commit was made, but HEAD is now …` (exit 3) | HEAD moved *during* the commit; the work is on the branch the message names | Recover exactly as in the first row. The commit is not lost, only misfiled |
| `guarded-push: ALERT — … is NOT this HEAD` (exit 4) | `git push` exited 0 without delivering this HEAD (a `remote.<name>.push` refspec, a `--dry-run`, a rejected-then-retried push) | Treat the work as **unpushed**. Find what the remote branch actually holds before pushing again; the exit code claimed a delivery the remote does not confirm |
| `tick-plan: ALERT — … now has an EMPTY body` | A body was written empty despite the guards (should be unreachable) | Restore immediately from `/tmp/plan-$ISSUE.orig.md`, then file a bug — the guard has a hole |
