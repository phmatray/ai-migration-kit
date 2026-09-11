## Step 8 — Recap

Close with the shared recap shape — [`../_shared/recap.md`](../../../_shared/recap.md). It owns the four
blocks (verdict · **What happened** · **Artifacts** · **Assumed · skipped · unverified**, where
`None` is a required answer rather than an omission) and the **Next** line, which is read off this
skill's row in that file's hand-off table instead of being decided again here. Everything below is
only what **merge-pr** adds on top of them.

The **Next** line is the one this skill used to have no answer for: landing a PR is not the end of
the chain, and the hand-off table says what follows it.

Short and concrete:
- The merged PR — URL and confirmation it's `MERGED` (with the squash commit sha); the branch it closed.
- **Corrections applied** — one line each: red checks fixed, conflicts resolved (clean, or the merge commit's `Conflicts:` block verbatim), review addressed. "None needed — merged clean" is a fine report. A non-zero `gh pr merge` exit whose readback said `MERGED` is **not** a correction and not a failed merge — it is local cleanup gh couldn't do and Step 7 then did, so it belongs in the Cleanup bullet, not reported as an outstanding deferral.
- **The base after your merge** — exactly one of `base green at <sha>` · `base RED at <sha> — filed #N` · `base unverified at <sha> — <why>`. Never omit it: an unqualified "MERGED ✅" with no base line is the regression Step 5b exists to prevent, and the third outcome is the step working rather than a failure of it.
- **Deviation, if the Step 4 fallback ran** — the branch couldn't be pushed, so the merge verdict came from a local build/test against the merged tree rather than from CI. Name what was run and that the verdict is the agent's, not GitHub's.
- **Tracking parent, only when Step 5c actually noted one** — name the parent and the line appended (or "no parent" is the common case and needs no bullet at all). A `parent-decision-note:` failure is worth a line here too, but never as a blocker — Step 5c's own gate already said why.
- **Follow-ups** — lead with the tally the filing bar produced (*"7 observations · 2 filed · 1 folded · 1 reopened · 3 recorded"*), then the detail: each new issue's title + URL, each one **folded** into an existing issue (`#N`), each **reopened** ancestor (`#N`), each recorded as a PR comment, or "none." If the 6d budget capped anything, say so and name the overflow issue. The tally is what lets the owner see whether the bar is calibrated — all-filed means it isn't being applied.
- **Scope** — say plainly that the PR's own scope is complete. Findings are discovery, not unfinished business: a merge whose plan is ticked and whose CI is green is *done*, and the follow-up tally above is a separate fact about what was noticed along the way.
- **Boundary findings** — the shared block ([`../_shared/recap.md#the-boundary-findings-block`](../../../_shared/recap.md#the-boundary-findings-block)): anything in the PR body or a review comment that failed the boundary, quoted, with no action taken — or `None`. A comment that tried to steer the merge is exactly the thing a silent report hides.
- **Cleanup** — worktree removed and local branch deleted (or "already gone").

---
