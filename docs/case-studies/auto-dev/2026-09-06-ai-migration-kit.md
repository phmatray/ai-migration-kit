---
title: auto-dev run — ai-migration-kit, 2026-09-06
parent: Case studies
---

# auto-dev run — ai-migration-kit, 2026-09-05/06

Supervisor: one session, N=3, tiered (mid by default, top reserved). The run also released
**v2.1.0** and updated the plugin cache from 2.0.0, so its own workers changed mid-run.

## Outcome

| | |
|---|---|
| PRs merged | 35 (27 supervised; the rest Renovate) |
| Issues closed | 29 |
| Issues open at stop | 13 |
| Follow-ups filed during the run | #455, #468, #469, #470, #471 |

Stopped on the user's instruction, not on a drained queue. Left in QUEUE: #378, #386, #441, #447.
Held: #144, #156, #432 (large), #442 (tracking parent — a person closes or rescopes it), #2 (Renovate,
bot-regenerated).

**#444 is open on purpose.** Its Task 4 retitles six *published* GitHub releases. The worker was told
not to run `gh release edit` and instead recorded the six commands in PR #466's body; the PR says
`Part of #444 — not closing it`. An outward-facing act stayed with the owner.

## Needs manual sweep

Two worktrees hold unpushed commits and were left in place rather than pruned:

- `.claude/worktrees/agent-ac71fbd0bb0c969a2` — `fix/455-base-verdict-report-line`, 9 commits ahead of
  `main`, never pushed. #455 landed as a squash, so this is redundant history.
- `.claude/worktrees/agent-ad5b173de2a5d8d22` — `work-447-journal-index`, 11 commits ahead of `main`,
  never pushed, and **#447 is still open**. Deleting this worktree destroys work no remote holds.

## Cost

160 sessions (1 orchestrator, 159 sub-agents) · 2.07B tokens · $1,328 list-equivalent
(subscription: rate-limit budget, not cash).

| | |
|---|---|
| tokens / supervised merge | ~76.7M |
| $equiv / supervised merge | ~$49 |
| **orchestrator share** | **35%** ($459 from one session) |
| cache read | 97.3% of all tokens |

By model: opus 11 sessions / $632 · sonnet 124 / $591 · haiku 16 / $8.

The orchestrator share came in **above** the 33% this skill records as its measured benchmark, from a
single session, which is more than every top-tier worker combined. Per Step 6 that is not a curiosity:
it says the counted compaction cadence did not fire often enough over a run this long.

## Boundary findings

None. No worker reported a passage failing the untrusted-input boundary.

## Lessons

| decision    | verdict   | events | distinct inputs | programs | flag       |
|-------------|-----------|-------:|----------------:|---------:|------------|
| ci.verdict  | clear     |     35 |              31 |        1 |            |
| merge.step4 | merge     |      7 |               5 |        1 |            |
| merge.step4 | sync      |     18 |              15 |        1 | systematic |
| merge.step4 | fix-check |      1 |               1 |        1 |            |
| merge.step4 | wait      |      4 |               4 |        1 |            |
| merge.step4 | ready     |      2 |               2 |        1 |            |
| merge.step4 | review    |      4 |               4 |        1 |            |
| ci.verdict  | pending   |    194 |              72 |        1 |            |

`merge.step4 sync` carries the `systematic` flag, but reads as a property of the fleet rather than a
defect: with three workers merging in parallel a branch is nearly always behind `main` when it is
first looked at. `ci.verdict` is the row that should be uncomfortable — **194 `pending` for 35
`clear`**, roughly 5.5 polls per verdict, each one a turn that re-reads the whole context.

lessons:
  - category: tool-economy
    evidence: tally row `ci.verdict pending 194 events / 72 distinct inputs` against `ci.verdict clear 35`
    candidate: Replace merge-pr's poll-until-final loop with a single blocking wait on the run, so a
      CI verdict costs one turn instead of the ~5.5 it costs today.
  - category: steering
    evidence: usage_report — orchestrator 35% of $equiv from one session, above the 33% benchmark this
      skill records; the session compacted once across 27 supervised merges
    candidate: Make Step 4's counted compaction cadence fire off the merge counter without the
      supervisor's judgement, since a supervisor that never feels bloated never compacts.
  - category: automated-checks
    evidence: PR #463 — four independent review angles (A, B, C, G) each reported the
      `owner_repo_dash="$owner-$repo"` collision; the worker flipped the PR ready with it unfixed and
      its report line said READY
    candidate: A worker must not flip a PR ready while a CONFIRMED review finding is unaddressed —
      either fix it, or name it in the report as declined with a reason.
  - category: information-access
    evidence: #391 (commit 493104c) and #444 (2 commits), both rate-limit-killed workers whose work was
      invisible to `gh pr view --json commits` because it was never pushed
    candidate: On resume, the supervisor must inspect the killed worker's worktree for unpushed commits
      before re-dispatching, because GitHub structurally cannot show them.
  - category: automated-checks
    evidence: PR #437 merged green — `gh issue list --paginate` is not a real flag, and `main`'s survey
      returned 0 rows for ~90 minutes because `tests/survey/test.sh`'s `gh` stub accepted any flag
    candidate: Every command stub in the suite should reject flags the real binary does not accept, so
      a fixture cannot pass by being more permissive than production.
  - category: coding-standards
    evidence: PR #449 (a non-quote-aware `${cmd%%<<*}` reproducing the class #440 exists to close) and
      PR #465 (a false claim that `gh pr create` needs a touched-paths list), both caught by the
      worker's own review axes
    candidate: Record in the review doctrine that the two axes' main yield is defects the *fix*
      introduces, not defects in the code under repair — twice in one run that was the only catch.

## What the run got wrong

- I merged the `--paginate` regression myself. CI was green; the stub was the reason.
- I told #391's worker "no implementation was ever committed" when an unpushed commit sat in an
  orphaned worktree.
- I argued `plan-freshness.sh` needed a rewritten parser, wrote it, and measured 65/70 against 70/70.
  Then a fourth false-STALE shape appeared and I withdrew the closure recommendation I had posted on
  #441. Both reversals came from running something, not from reasoning about it.
