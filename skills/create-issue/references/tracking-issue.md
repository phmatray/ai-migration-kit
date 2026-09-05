# The tracking parent — the body of a decomposed issue's parent

When `create-issue` Step 6 decides a plan is too large for one worker (see
[`decomposition.md`](decomposition.md)), it files **one parent and N children**. The children carry
the plans; the parent carries the **map**: the whole job at low resolution, loaded once per session,
never executed. This file is the parent's body shape and the one invariant that makes it safe.

Ported from mattpocock/skills `engineering/wayfinder` (MIT) — the map body (Destination · Notes ·
Decisions so far · Not yet specified · Out of scope) and the "refer by name" rule are Matt Pocock's;
the plan-token invariant and the `survey.sh` consequence are this kit's. The wayfinder's decision
tickets (research / prototype / grilling / task, one per session) are deliberately **not** ported: the
kit charts work to build, not decisions to make.

## Why the parent has no plan

`auto-dev`'s `survey.sh` decides what a worker may be handed with one regex, tested against the body
and — since #343 — every comment too:

```
haveplan: test("Implementation plan|### Task|- \\[ \\]")
```

A body that matches is a candidate; one that does not lands in `SKIP` and is never dispatched. The
parent of a decomposed job must be the second kind — it is a job no single context can hold, which is
the very reason it was split — so its body carries **none of the three tokens**:

- not the exact, case-sensitive string `Implementation plan` (not even in prose: *"see each child's
  Implementation plan"* is a match — write *"each child carries its own plan"*);
- no `### Task` heading;
- no `- [ ]` checkbox anywhere, which is why *Decisions so far* below is a plain bullet list and why
  the parent's 📋 Spec keeps its acceptance criteria numbered, as the Spec contract already requires.

This is **load-bearing, never to be relaxed** — but the body-only property is a fact about the BODY,
and once `haveplan` also reads comments (#343) a stray comment on the parent (a status update, a
pasted child plan) could otherwise grant it one by accident. `survey.sh` guards this explicitly: a
body carrying the `## Destination` heading below with none of the three tokens is read as a tracking
parent, and no comment may grant such an issue a plan — only the body can. `tests/survey/test.sh`
carries two parent-shaped fixtures asserted `SKIP` (one plain, one with a plan-bearing comment) so a
later edit to the jq cannot break either silently, and Step 7's readback counts the parent's
checkboxes and refuses anything but `0`.

## The body

Top to bottom — the template fields, the `**Related:**` line, then the two collapsible sections exactly
as a single issue carries them, then the map:

```markdown
## Problem
<the whole job, from the user's side — why it is one job and why it is too big for one PR>

## Proposed solution
<one paragraph naming the slices and their order; the children hold the detail>

## Area
<the parent's area — every child inherits it>

**Related:** #N, #M

<details>
<summary><b>🧠 Brainstorm</b></summary>

…

</details>

<details>
<summary><b>📋 Spec</b></summary>

… the design for the whole job, ending with the contract: numbered `### Acceptance criteria` for the
job as a whole, `### Testing decisions` naming the seams the children will share, and the
`### Out of scope` the children inherit …

</details>

## Destination

<what done looks like for the whole job — one or two lines; every child and every session orients to
it before choosing what to pick up>

## Notes

<invariants every child obeys; the skills and references a worker on any child should consult; the
expand → migrate → contract order when the job is a wide refactor; anything a child must not do alone>

## Decisions so far

- none yet — appended as children land

## Not yet ticketed

<in-scope fog: work the job will need that is not yet sharp enough to be a child. A patch here may
graduate into one child or several, or into none, once the frontier reaches it. "None" is a valid
entry; an empty heading is not>

## Out of scope

- <ruled out of this job — copied from the Spec's Out of scope, so a reader of the map need not open
  the Spec to know where the boundary is>
```

Three things the map is and is not:

- **An index, not a store.** *Decisions so far* gists and links; the detail lives in the child (its
  body, its PR, its closing comment). A decision written twice drifts.
- **Open children are not listed.** They are found by query — `Part of #P` in their bodies, the
  sub-issue link, the frontier filter (`issue_dependencies_summary.blocked_by == 0`, open,
  unassigned). A hand-kept list of open children goes stale the first time one is added or closed
  on the side.
- **Not yet ticketed ≠ Out of scope.** The first is work toward the destination that is not yet sharp
  enough to be a child; the second is work ruled beyond the destination, which never graduates. The
  test for the first is *can the child be stated precisely now?* — not *can it be done now?*

## Decisions so far — the append rule

One line per child that has **landed**:

```markdown
- #<child> — <the landing PR's title, trimmed of its trailing "(#issue) (#PR)"> ([#<PR>](<url>))
```

Today `create-issue` seeds the list with `none yet`, and `triage-backlog`'s rescope seeds it with the
**prior attempts** the rescope cites (each closed or folded issue by title, with what it got done).
Appending as a child's PR merges is `merge-pr` Step 5c, via
`skills/merge-pr/scripts/parent-decision-note.sh` (#365) — idempotent per PR number, so a resumed
merge never duplicates the line. It fires only when the closed issue carries a **native** `parent`
(the sub-issue relationship `wire-edges.sh` writes); the `**Blocked by:** #N` prose-fallback shape
has nothing for it to read, so the owner still appends that line by hand on a host without the
sub-issues API.

## Refer by name, then number

Every parent and child is an issue, so it has a **name**: its title. In everything a human reads —
the Step 8 recap, *Decisions so far*, the `**Blocked by:**` line of a child — refer to it by that
name **with the number in parentheses** or as the link text's target: **Wire-edges script** (#412),
never a bare `#412`. A wall of `#410, #411, #412` is illegible; names read at a glance, and the number
rides inside so the link still works. The one place the bare number is the point is a command
(`/implement-issue #412`).

## Recognising a parent

There is no tracking label. A parent is the issue whose body carries a `## Destination` heading and
whose children carry `Part of #<its number>` at the top of theirs. `gh api repos/o/r/issues/P/sub_issues`
lists them when the sub-issue API is on; the `Part of` line is the fallback that always exists.
