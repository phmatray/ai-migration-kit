# When a guard at `$GUARDS` is refused

`$GUARDS` points at the kit's own `skills/implement-issue/scripts/` directory — deliberately, so
there is exactly one copy of `guarded-commit.sh`, `guarded-push.sh` and `guarded-merge.sh` rather
than a copy per consumer that drifts. When the kit runs as an **installed plugin**, that directory
is the plugin cache (`~/.claude/plugins/cache/<marketplace>/ai-migration-kit/<version>/…`), which
sits outside the repo entirely — and therefore outside the worktree an `auto-dev` or
`implement-issue` worker is confined to. A host or sandbox that pins an agent to one worktree can
then refuse to invoke a script that lives outside it, at the exact moment a commit needs to go
through the guards rather than around them.

**This does not apply to `make-worktree.sh`.** That call runs *before* any worktree exists, from the
main checkout, where `$GUARDS` resolving to the kit's own directory is not a problem — there is
nothing yet to be confined to. The fallback below is for the *later* calls —
`guarded-commit.sh`, `guarded-push.sh`, `guarded-merge.sh` — which all run **inside** the worktree
`make-worktree.sh` just created, where the same path can now be the thing that gets refused.

## The fallback

If invoking a guard at `$GUARDS` is refused:

1. **Copy the guard scripts, and `_assert-branch.sh` alongside them**, into a scratch directory
   inside your **own** worktree — e.g. `"$WORKTREE/.git-guards"`. `_assert-branch.sh` is not
   optional: `guarded-commit.sh`, `guarded-push.sh` and `guarded-merge.sh` all source it for the
   branch assertion itself, and a copy that omits it breaks silently rather than loudly.
   ```bash
   mkdir -p "$WORKTREE/.git-guards"
   cp "$GUARDS/guarded-commit.sh" "$GUARDS/guarded-push.sh" "$GUARDS/guarded-merge.sh" \
      "$GUARDS/_assert-branch.sh" "$WORKTREE/.git-guards/"
   ```
2. **Run them from there** — same arguments, same `-C "$WORKTREE"`, same `$BRANCH` — nothing about
   the guard's behavior changes, only where it was copied from.
3. **Delete the scratch directory before finishing** — it must never reach the commit or the diff:
   ```bash
   rm -rf "$WORKTREE/.git-guards"
   ```
   A worktree's ignore rules are a fact about the repository, not something to assume; if
   `.git-guards/` is not already covered by an ignore pattern, deleting it before the final commit
   is what keeps it out regardless.
4. **Report that you did it.** Copying the guards is a deviation from the documented path, and it
   belongs in the run's structured report so a supervisor's recap can see it — a deviation that
   surfaces nowhere is indistinguishable from one that never happened.

**Never fall back to a bare `git commit`, `git push` or `git merge`.** That is precisely the failure
the guards exist to prevent (#26, #280, #41) — a refused guard is a reason to relocate it, not a
reason to bypass it.
