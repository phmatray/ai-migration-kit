## Step 5 — Open the draft PR

**Skip this step entirely if Step 4's issue-scoped fallback resumed onto an existing PR** — that PR
already carries a scaffold commit (or real work), and opening another one is exactly the failure this
guard exists to prevent. Go straight to Step 6.

Otherwise: the PR should be visible as a **draft before** the implementation loop. A PR needs the
branch ahead of `main`, so land an empty scaffold commit, push, then open it.

**Follow the profile's *PR title convention*.** The common shape is a Conventional Commits prefix
_and_ a `(#<issue>)` suffix — two independent constraints, both enforced, e.g.
`feat(export): stream CSV report downloads (#172)`.

- **Prefix** — when the profile notes a Conventional Commits gate, start with `<type>[(scope)]: `,
  where `<type>` is one of `feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert`. A
  semantic-PR-title CI check rejects the PR otherwise, and on a squash-merging repo the PR title
  *becomes* the commit on `main` that release automation (e.g. `release-please`) parses to cut the
  next version — a bare title produces no release. **Issue titles are not conventional** — "CSV
  export: header row missing…" reads like a scope but `CSV export` is not a valid *type* — so supply
  the prefix yourself; never pass the issue title through verbatim.
- **Suffix** — end with `(#<issue>)`, the *issue* number. When the profile's *Integration style* is
  squash-merge, GitHub appends the *PR* number to the squash commit's title — so titling with the *issue*
  number makes the final `main` commit carry **both** (`… (#254) (#274)` — issue first, PR second). Drop
  it and the merged commit records only the PR number, losing the link to the issue.

Pick the **type** from the change, not a guess: the issue's type label maps cleanly (`bug` → `fix`,
`enhancement` → `feat`) — use it. When it doesn't map cleanly, build a candidate type from the plan's
own shape as before (`docs:` for prose, `ci:`/`build:` for CI plumbing, `refactor:`/`test:` for a pure
refactor or tests-only change), then **dry-run the real gate against the touched-paths list from the
plan's own `Files` lines** (already parsed in Step 2 — no real diff exists yet at this point, since
the PR opens off an empty scaffold commit with no file changes of its own):
`scripts/release-title-gate.sh "<candidate-type>(<scope>): <subject> (#$ISSUE)" <the plan's Files paths>`.
Never hand-classify a path as "genuinely non-shipped" against a memorized example list — the gate's
actual `NON_SHIPPED`/`SHIPPED_ANYWAY` rules are longer than any such list and carve specific paths
back into "shipped" by name, and a hand-copied approximation has already drifted from them twice
(#233, #245, #258). On exit 1 (refused), retry with `fix:` (or `feat:` when the issue's own label
says enhancement) instead of the rejected type — a shipped-path PR is restricted to
`feat`/`fix`/`perf`/`revert` regardless of how prose-like or mechanical the diff reads. Exit 0 means
the candidate is releasable; use it as-is. **Exit 2 is not a verdict about the title — it is a broken
call**: the plan's `**Files:**` lines yielded no usable path, so the gate had nothing to classify
(#470). Do not pick a type blind; the plan is the defect — fix its `**Files:**` line (a task with
no files says `none expected.`, the idiom `scripts/plan-freshness.sh` recognizes) and re-run the dry-run with the paths
it then yields. This check runs the moment the PR is opened, so a bad guess
here becomes a red `title-gate` check almost immediately, not a late-stage surprise. Add an optional
**scope** matching the ones already in `git log` for the touched area (the profile's area names
usually fit).
Then write a concise imperative **subject** that summarizes the fix rather than echoing the issue's
symptom wording — so the example issue becomes e.g.
`fix(export): use invariant culture in CSV number formatting (#849)`.

Every commit and push **in Steps 5–9** goes through the guards in `scripts/` — never a bare
`git commit` or `git push`. They take `$BRANCH` explicitly, refuse (exit 2) when HEAD is anything else
or detached, and prove afterwards that the commit landed on that branch (exit 3 if not) and that the
remote really carries this HEAD (exit 4 if it does not — or if the guard could not find out; Step 6
says how to tell those apart). `-c user.email=… -c user.name="…"` is the profile's
*Commit identity*; it goes **before** `$BRANCH`, because those are options to `git`, not to
`git commit`.

Step 8 is no exception: it delegates to
[`../_shared/sync-with-main.md`](../../../_shared/sync-with-main.md), whose merge, completing commit and
push all go through the same three guards (#41) — `guarded-merge.sh` included, since a merge commit
is the largest single write in this flow. That file reads `$BRANCH`, `$WORKTREE` and `$GUARDS`, which
is why Step 4 records them.

```bash
"$GUARDS/guarded-commit.sh" -C "$WORKTREE" <commit-identity> "$BRANCH" \
  -- --allow-empty -m "chore(#$ISSUE): scaffold draft PR for <title>"
"$GUARDS/guarded-push.sh" -C "$WORKTREE" "$BRANCH" -- -u origin "$BRANCH"
gh pr create --draft --base main --head <branch> \
  --title "<type>(<scope>): <subject> (#$ISSUE)" \
  --body "Implements #$ISSUE.

Closes #$ISSUE.

Executing the implementation plan task-by-task; the checklist below — and the plan on the issue — are
ticked as each task lands. Opened as a draft — will be marked ready after the final task and a
code-review pass.

### Plan
- [ ] Task 1: <name>
- [ ] Task 2: <name>
<one \`- [ ] Task N: <name>\` line per \`### Task N\` heading in the plan>"
```

Capture the PR URL/number. (If a PR for this branch already exists, reuse it.) The PR's `### Plan` list
is a task-level mirror (coarser than the issue's per-step boxes) for at-a-glance reviewer progress; Step
6 keeps it in lock-step. The issue plan stays the **canonical** source of truth — it's what a resumed
run reads.
