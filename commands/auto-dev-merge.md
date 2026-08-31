---
description: Run PHASE 2 of an auto-dev worker — land an already-ready PR via merge-pr, in a FRESH context. Dispatched by the auto-dev supervisor as a background sub-agent after the phase-1 sub-agent reports a PR number; invoke as `/auto-dev-merge <pr-number>` (the model tier is the `model` the supervisor passed to the Agent tool, not here).
argument-hint: <pr-number>
---

You are an auto-dev worker (**PHASE 2 of 2**) for this repo. Phase 1 already implemented the issue and
flipped **PR #$1** to ready.

YOUR ONLY JOB: land PR #$1. Invoke `merge-pr` with args "$1" and drive it all the way to MERGED —
clear whatever blocks it (red/flaky checks, conflicts with the default branch, unresolved review
threads), squash-merge, file any follow-ups, and tear down the branch and worktree. Do NOT go idle
while a merge is still achievable. Only stop for a genuine hard blocker.

You are starting with a **fresh, nearly empty context** — that is the entire point of this phase (the
same merge work inside phase 1's context ran at ~247K tokens/turn; here it runs at a fraction of
that). Protect that advantage:

- **Orient in ONE batched turn.** Get PR state, diff stat, and branch state together, e.g.
  `gh pr view $1 --json number,title,isDraft,mergeStateStatus,headRefName && gh pr diff $1 --stat && git -C <worktree> log --oneline -5`.
  Do not make a series of single lookups.
- **Never read the whole diff into context** unless a conflict actually requires it — `--stat` first,
  then only the conflicting files.
- **Big command output goes to a FILE; only a summary enters context:**
  ```bash
  dotnet test > /tmp/merge-$1.log 2>&1; echo "EXIT=$?"
  grep -c 'Passed!' /tmp/merge-$1.log
  grep -E 'Failed!|error CS|error MSB' /tmp/merge-$1.log | head -20
  ```
  `EXIT` is the gate. Do not pipe the command itself through `tail`/`head` — that truncates the
  evidence you need.

OFF-SCOPE PROTOCOL: anything you trip over that is not part of landing PR #$1 gets FILED via
`create-issue`, not fixed inline.

Repo specifics (default branch, merge mode, CI state, commit identity) come from the repo profile,
which `merge-pr` loads.

Your FINAL message must be this single line and nothing else:

ISSUE: <number of the issue this PR closes, digits only> | PR: $1 | STATUS: MERGED|BLOCKED|FAILED | DETAIL: <1–2 sentences> | FILED: <issues you opened, or none> | WORKTREE: <cleaned up / what remains>
