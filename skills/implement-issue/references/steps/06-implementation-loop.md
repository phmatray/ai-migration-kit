## Step 6 — The implementation loop

**First, on any resume, reconcile the PR's `### Plan` mirror with the issue's canonical plan**:
any task whose issue block is fully `- [x]` must be ticked in the PR list too. The issue PATCH
and the PR-body edit below aren't atomic — a crash between them in a previous run leaves the
mirror stale, and nothing else ever re-syncs it (recipe: `references/github-mechanics.md` §4).

Then, for each task in plan order whose checkboxes aren't all `- [x]`:

1. **Implement it.** Follow the task's own TDD-first steps (write the failing test → run red →
   implement → run green). Honor the Global Constraints and the profile's *Architecture grain* (touch
   layers in order, don't break invariants). Use the per-task test filter the plan gives. Name new
   files, symbols and test cases from the target repo's root `CONTEXT.md` when it has one; a term
   the glossary lists under `_Avoid_` does not become an identifier.

   **In a target repo with C#, existing code is read and changed through RoselineMCP**, never
   through Read/Grep/Edit on a `.cs` file: `search_symbols` to locate a type or member,
   `get_symbol_info` (`includeSource: true`) to read one, `find_references` before touching an API
   used elsewhere, `edit_member` / `rename_symbol` (preview first) for the change. The kit's own
   `hooks/roseline-gate.sh` denies a `Read` on a `.cs` file and names the replacing tool, so this
   is the rule the gate enforces rather than a preference; `Edit` stays for what roseline cannot
   reach — `using` directives, attributes, file-scoped namespaces, top-level statements
   (`docs/roseline-gate.md`). Hand the same rule to every per-task sub-agent's brief.
   - *Inline mode:* directly, per [`../_shared/tdd-loop.md`](../../../_shared/tdd-loop.md) — red before
     green, one slice at a time, refactoring left to Step 7.
   - *Subagent-per-task mode:* dispatch a subagent with the task block, Global Constraints, repo grain, the target repo's root `CONTEXT.md` (or that it has none), and the **path** to Step 3's `/tmp/issue-$ISSUE-notes.md` (a pointer — it reads them itself); have it implement to a green filtered test run and report a short diff summary.

   **The failing test crosses the seam the plan named for this task** — the preamble's
   `**Seams under test:**` line, and the seam each failing-test step names in the task block itself
   (`create-issue` Step 5 writes both). A test that instead *mocks* that seam, asserts a call count
   across it, or recomputes its expected value the way the code under test computes it is not the
   test the plan asked for: the first two assert the plumbing you wrote rather than the behaviour a
   caller depends on, and the third can never disagree with a bug. Write it at the seam, and if the
   named seam turns out to be the wrong place, say so in the report rather than quietly moving it —
   the substitution is a finding for Step 7's Spec axis. The doctrine, with the worked example in
   this tree, is [`../_shared/test-seams.md`](../../../_shared/test-seams.md).

2. **Verify green before you commit.** Run the task's test filter and confirm it passes — read the
   output, don't assume. A red bar means it isn't done; fix it or stop. Never commit over failing tests.

3. **Commit** with the project identity and the **commit message from the task's final step** —
   through `guarded-commit.sh`, which refuses rather than let the work land on a branch that was
   checked out under you:
   ```bash
   "$GUARDS/guarded-commit.sh" -C "$WORKTREE" <commit-identity> "$BRANCH" \
     -- -am "<message from the task's last - [ ] step>"
   ```
   A non-zero exit is never something to retry blindly: **2** means nothing was written and HEAD is
   on the wrong branch (fix that first), **3** means the commit exists somewhere else and the message
   names where.

4. **Tick the task — on the issue plan AND the PR description.** Flip it in **both** so neither goes
   stale (issue canonical, PR list its mirror). In each file flip *only this task's* `- [ ]` lines
   with the **Edit tool per line** — never a blunt `sed s/\[ \]/[x]/g`, which ticks *other* tasks
   too. Then write the issue plan back **through `scripts/tick-plan.sh`, never by piping `jq`
   straight into `gh api`** — that pipeline wiped two live issue bodies, and it fails silently
   with exit 0 (see `references/github-mechanics.md` §4):
   ```bash
   ./skills/implement-issue/scripts/tick-plan.sh \
     --repo {owner}/{repo} --issue "$ISSUE" \
     --before /tmp/plan-$ISSUE.orig.md --after /tmp/plan-$ISSUE.md
   ```
   It refuses unless the new body is the old one with checkbox characters — and nothing else —
   changed, so a missing, empty or truncated file can never reach GitHub. The PR mirror is a
   plain `gh pr edit --body-file`. Exact recipes for both paths: `references/github-mechanics.md` §4.

   **Both of its `gh` calls run under `TICK_PLAN_PATCH_TIMEOUT` (default 60s), and expiry is not
   failure** — killing a call does not un-send it, so the read-back decides (#135). Two lines to
   recognise, neither of which means the tick is lost:
   - `the PATCH … exceeded 60s and was bounded` — informational; **read the next line** for the
     verdict.
   - `ALERT … re-run the tick` (exit 1) — **re-run it, unchanged; it is idempotent.** Do **not**
     restore from `/tmp/plan-$ISSUE.orig.md`: a write that was cut short may still arrive, and the
     restore would silently un-tick it.

   If a tick ever takes minutes, that is a bug in the script and not a slow network — it was one
   until #135. Say so rather than raising the timeout.

5. **Push** so the PR reflects the new commit — through `guarded-push.sh`, which reads the remote
   back and requires it to equal this HEAD:
   ```bash
   "$GUARDS/guarded-push.sh" -C "$WORKTREE" "$BRANCH"
   ```
   Exit **4** means the remote was **read** and **disagrees** with the push — the guard is making a
   positive claim, not a shrug (#172). `… is NOT this HEAD` / `… has no '<branch>' to show for it`
   is the silent mis-push, the remote contradicting the delivery; `HEAD moved while it ran` means
   the push may have carried another branch instead. For either, go and look at what the remote
   actually holds before pushing again.

   Exit **6** is a different answer: verification **never ran** — `… could not be listed` /
   `push is UNVERIFIED`. Nothing here disproves the push, and nothing here confirms it either.
   **Don't act on this code alone.** Fix what broke the listing (a `--remote` naming a remote the
   push never wrote to, connectivity, credentials), then re-run with **`--verify-only`**
   (`"$GUARDS/guarded-push.sh" -C "$WORKTREE" --verify-only "$BRANCH"`) — it repeats the branch
   assertion and the remote read-back without pushing again, which is the precise way to find out.
   Per-condition recovery: the Troubleshooting table in `references/github-mechanics.md`.

Continue until no task has an unchecked box. The issue's plan now reads all-`- [x]`.
