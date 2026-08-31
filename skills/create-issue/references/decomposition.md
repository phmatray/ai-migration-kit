# Decomposing large work — tracer-bullet children with blocking edges

`create-issue` Step 6 takes this branch when the plan it just wrote would earn the profile's
**largest effort size** and `--no-split` was not passed. Instead of one `effort: large` issue that
`auto-dev` holds forever and no single worker context can carry, it files a **parent** (the map — see
[`tracking-issue.md`](tracking-issue.md)) and **N ≥ 2 children**, each a vertical slice with its own
plan, its own effort (small or medium), and its **blocking edges** wired natively on GitHub.

Ported from mattpocock/skills (MIT): `engineering/to-tickets` (tracer-bullet vertical slices, blocking
edges, expand–contract for wide refactors, publish blockers first so edges can reference real
identifiers) and `engineering/setup-matt-pocock-skills/issue-tracker-github.md` (sub-issues, native
dependencies by database id, the frontier query). Credit belongs to Matt Pocock. What is deliberately
**not** borrowed is listed at the end.

## Why slices are vertical

A large plan written as one issue is horizontal by habit — *Task 1: the scripts, Task 2: the SKILL.md,
Task 3: the tests* — so nothing is demoable until the last task lands and a half-finished PR has no
green state. A **tracer bullet** cuts a narrow but complete path through every layer instead, so each
child is a PR that lands green and shows something working.

<vertical-slice-rules>

- Each slice cuts a narrow but **complete** path through every layer the job touches — for this kit:
  the script, the skill prose that drives it, and the golden test that proves it. Never "all the
  tests" or "all the docs" as a slice of their own.
- A completed slice is **demoable or verifiable on its own** — a reviewer can run something and see
  the behaviour, with the siblings still open.
- Each slice is **sized to one worker context** — in the kit's measure, a plan that earns
  `effort: small` or `effort: medium`. A child that would be `effort: large` is not a slice; split it
  again. (#272 measured the cost of a context that overflows: three of thirty-seven sessions took a
  third of a run's spend.)
- **Any prefactoring is its own first slice** — "make the change easy, then make the easy change" —
  and every slice that needs it is blocked by it.

</vertical-slice-rules>

## Blocking edges

Give each child the set of children that **must complete before it can start**. The rules:

- **The minimum that genuinely gates.** An edge is a claim that the blocked child cannot land green
  without the blocker merged — a shared script it calls, a heading it appends to, a fixture it
  extends. "Nicer if done first" is not an edge.
- **A child with no blockers can start immediately.** Say so on its `**Blocked by:**` line (`none —
  can start immediately`); that set is the initial **frontier**.
- **The parent is never a blocker**, and never blocked: it is a tracking issue. `wire-edges.sh`
  refuses an edge that names it.
- **No cycles.** If two slices each need the other first, they are one slice or the seam between
  them is a prefactoring child both are blocked by.

The **frontier** at any moment is the set of open, unblocked, unassigned children — what `auto-dev`
may dispatch (reading `issue_dependencies_summary.blocked_by == 0` is #317's job; today the text
line is what a human reads). For a purely linear chain the frontier is one child at a time, top to bottom.

## Wide refactors: expand → migrate → contract

A **wide refactor** is one mechanical change — rename a shared helper, retype a manifest field, move
a heading every skill anchors on — whose **blast radius** fans across the whole tree, so a single
edit breaks every call site at once and no vertical slice can land green. Do not force it into a
tracer bullet; sequence it as **expand–contract**:

1. **Expand** — one child adds the new form *beside* the old, so nothing breaks. No blockers.
2. **Migrate** — N children move the call sites over in batches sized by blast radius (per directory,
   per suite, per skill), **each blocked by expand**. CI stays green batch to batch because the old
   form still exists.
3. **Contract** — one child deletes the old form once no caller remains, **blocked by every migrate
   batch**.

When even the batches cannot stay green alone, keep the sequence but let them share an integration
branch that all block a final integrate-and-verify child; green is promised only there.

## The child body

```markdown
Part of #<parent> — <parent title>.
**Blocked by:** <Blocker title> (#a), <Blocker title> (#b)   ← or: none — can start immediately

## Problem
<one paragraph: the slice's end-to-end behaviour, from the user's side — what works once this lands
that does not work today>

## Proposed solution
<the slice, in this kit's terms: the script, the prose, the test>

## Area
<the parent's area, verbatim>

<details>
<summary><b>📋 Spec</b></summary>

… the design of THIS slice, ending with the contract: numbered `### Acceptance criteria` for the
slice, `### Testing decisions` (its seam — usually one of the seams the parent's Spec named),
`### Out of scope` (the parent's, plus what a sibling owns) …

</details>

## 🛠️ Implementation plan
<the full Step 6 shape — header note, Goal / Architecture / Tech stack, `**Seams under test:**`,
Global Constraints, `### Task N` blocks with **Files** / **Interfaces** and every step a `- [ ]`
checkbox, the last one the commit message>
```

Two lines at the top, before the first heading, so they are the first thing `implement-issue` and a
reader see. The `**Blocked by:**` text line is **always written**, wired or not: it is the
representation that survives when the dependency API is off, and it is what a human reads on the
issue page without opening the sidebar. Blockers are named **title first, number in parentheses**.

A child has **no 🧠 Brainstorm** of its own — the parent brainstormed the job; a child that needs its
own brainstorm is a sign it is a second job.

**Labels.** A child carries the parent's type, priority and area labels **verbatim** and its **own
effort** (small or medium). A slice that needs a different area than its parent is a sign the parent
is two jobs — split the parent, not the label.

**Titles.** House style, same as any issue in this repo: a declarative statement of what the slice
makes true. Distinct enough from its siblings that the name-then-number rule works in a report
(`**Wire-edges script** (#412)`, not `**Part 2** (#412)`).

## Creation order and the second pass

Issues need numbers before they can reference each other, so:

1. **File the parent** — the tracking body, zero checkboxes.
2. **File the children in dependency order, blockers first**, so each child's `**Blocked by:**` line
   can name real numbers. Topologically: every child with no blockers, then every child whose blockers
   are all filed, until none remain.
3. **Wire the edges in a second pass** with `scripts/wire-edges.sh` — one call, every child, every
   edge:

   ```bash
   skills/create-issue/scripts/wire-edges.sh --repo o/r --parent P \
     --child C1 --child C2:blocked-by=C1 --child C3:blocked-by=C1,C2
   ```

   It resolves database ids itself, posts each child as a **sub-issue** of the parent and each
   blocker as a native **`blocked_by`** dependency, and prints one line per edge: `ok`, `fallback`
   (the endpoint answered 404 — the feature is off on this host; the text line stands), or `FAILED`.
   Exit `0` when every edge is ok or fallback, `1` on any real API failure, `2` on bad arguments;
   `--dry-run` prints the POSTs and calls nothing. Re-running it is safe — an edge that already
   exists is `ok`.

4. **Read back**: the parent has `0` checkboxes, every child has `> 0`, and each child's
   `issue_dependencies_summary.blocked_by` equals its open blocker count (or the report says the
   dependency API fell back to text).

Do not close or modify any pre-existing issue the decomposition grew out of — a `--seed #N` that took
this branch becomes the parent in place, and a `triage-backlog` rescope cites the attempts under the
parent's *Decisions so far* rather than editing them.

## Explicitly not borrowed

- **"No file paths or code snippets in tickets."** Matt's tickets are read by a human who then
  explores; the kit's plans are *executed* cold by `implement-issue`, so every task keeps its
  `**Files:**` / `**Interfaces:**` lines. The kit's rule is the opposite: ground the plan in the tree.
- **The wayfinder decision-ticket protocol** (research / prototype / grilling / task tickets, one
  resolution per session, the `wayfinder:map` label). The kit charts work to build, not decisions to
  make; `--grill` already covers the one decision round a filing may need.
- **The five triage-role labels** (`needs-triage`, `ready-for-agent`, …). The kit's four axes plus
  `survey.sh`'s buckets already carry the dispatch state; children are agent-grabbable by
  construction because they carry a plan and an effort label.
- **A tracking label.** A parent is recognisable by its `## Destination` heading and its `Part of`
  children; a label would be a second place for the same fact to drift.
