# ai-migration-kit

The kit's own domain glossary: the terms its skills coin for the issue-queue lifecycle
(`create-issue` → `implement-issue` → `merge-pr` → `triage-backlog`) and the machinery those
skills share (gates, guards, profiles). Each term is defined once, here, so a later skill reaches
for the existing word instead of a synonym.

> Format ported from mattpocock/skills (`skills/engineering/domain-modeling/CONTEXT-FORMAT.md`,
> MIT). `create-issue` and `implement-issue` also read this same file at the root of whatever repo
> they are working on — this is the kit's own copy, and the first instance of the convention.

## The queue

**Inlet**:
A skill step that can create a GitHub issue on its own initiative. Three inlets write to the
queue today: `merge-pr` Step 6's follow-up capture, the `auto-dev` workers' off-scope capture, and
a direct `create-issue` run.
_Avoid_: source, entry point, feeder

**Outlet**:
The one step that removes work from the queue instead of adding to it — `triage-backlog`, which
re-decides what is already there (keep, sharpen, fold, rescope, or close by decision).
_Avoid_: drain, pruner

**Filing bar**:
The one standard (`skills/_shared/filing-bar.md`) every inlet applies before opening an issue on
its own initiative: pass one of three tests — a nameable consequence, a named instance already in
the tree, or a commitment already made — or the finding stays a record, not a queue item.
_Avoid_: threshold, triage criteria

**Record (vs file)**:
What an inlet does with a finding that fails the filing bar: leave it somewhere retrievable (a PR
comment) rather than opening an issue for it. Filing commits the queue to draining the work;
recording costs nothing to ignore until a later instance passes the bar.
_Avoid_: note, park

**Root / instance**:
A **root** is an open issue that owns a cause; an **instance** is one more occurrence of that
cause found later. `create-issue` Step 3 folds an instance into its root rather than filing it as
its own issue.
_Avoid_: parent/child (that's decomposition, not causation)

Note: `create-issue` and `merge-pr` both call an instance a **symptom** in prose ("fold a symptom
into the issue that owns its cause") — that usage is established and kept, not a synonym to avoid.

**Fold**:
Add a discovered instance to its root issue — as a checklist item or a comment — instead of
filing it as a separate issue (`create-issue` Step 3, `merge-pr` Step 6).
_Avoid_: merge (that's git), dedupe

**Seed**:
What `create-issue` does to a new issue before anyone picks it up: write a brainstorm, a spec, and
an implementation plan into the body, so an executor can run it cold instead of starting from a
bare title.
_Avoid_: enrich, flesh out

**Eligible set**:
The slice of the open backlog `auto-dev`'s survey actually hands a worker: open, carrying a plan,
a code task rather than manual QA, unblocked, and within the effort ceiling. Named for the term
`auto-dev/SKILL.md` already uses — this glossary reaches for it rather than coining a second one.
_Avoid_: frontier, ready queue, top of backlog

**Close by decision**:
An issue closed as *not planned* because it fails the filing bar on review — no consequence, no
instance in the tree, nobody asked — with the reason recorded in the closing comment rather than
left silent (`triage-backlog`, `review-followups`).
_Avoid_: wontfix, abandon

**Follow-up / next step / deferred**:
An open item tracked in a migrated repo's `migration/report.json`: `next_steps` for outstanding
work, `deferred` for something explicitly not being done now. `review-followups` consolidates these
across every migrated repo.
_Avoid_: todo, backlog item

## The machinery

**Gate**:
A point in a pipeline — a `migrate-legacy` phase boundary, a decision in `docs/decisions.md` —
that must resolve before the run continues. A failed gate stops forward progress; it is fixed or
rolled back, never skipped.
_Avoid_: check, checkpoint

**Verdict**:
The resolved outcome of a decision, drawn from the vocabulary declared for it in
`decisions/registry.json`. Only a genuinely resolved outcome counts — `skills/_shared/preconditions.md`'s
profile-load check has exactly two (the profile, or `NO_PROFILE`); every other exit means no
verdict was reached, which is not the same as a negative one.
_Avoid_: result, status, exit code

**Guard**:
A script under `skills/<skill>/scripts/` (or `scripts/`) that wraps a destructive git write —
commit, push, merge — refuses when a precondition isn't met, and re-reads state afterward instead
of trusting a zero exit code.
_Avoid_: helper

Note: `decisions/registry.json`'s `not_decisions` entries call these same scripts a "guarded …
wrapper" — that usage is established there and kept, not a synonym to avoid.

**Profile**:
The committed `.claude/skills/repo-profile.md`: the one source the lifecycle skills read for a
target repo's commit identity, build/test commands, CI gates, labels, and conflict hot-spots.
_Avoid_: config, settings

**Worktree home**:
The directory a skill's own git worktrees live under (`.claude/worktrees/`, `.worktrees/`) —
verified ignored before a worktree is created or reused, and never derived from the worktree
itself.
_Avoid_: worktree dir

**Worker / supervisor**:
A **worker** is one `auto-dev`-dispatched process taking a single issue from plan to merged PR;
the **supervisor** is the process above it that keeps N workers running, retires each the moment
its PR merges, and re-drives any stalled at "ready".
_Avoid_: agent, fleet member

Note: `auto-dev/SKILL.md` also calls the supervisor the **orchestrator** in a few places (its own
description block, the cost-accounting section) — both names are in live use there; this glossary
doesn't pick a winner.

**Area**:
The label axis (`area: docs`, `area: skills`, …) that partitions the tree into non-overlapping
slices — the axis `auto-dev` reads to hand each parallel worker a slice that won't collide with
another's.
_Avoid_: scope, component, module

**Phase**:
One of the seven numbered phases (1–7) of the `migrate-legacy` pipeline — README.md and the skill's
own frontmatter call it a "seven-phase" pipeline — each ending at a gate before the next one starts.
Phase 0 (preflight) runs before all seven and is numbered but not counted among them.
_Avoid_: stage, step

## Flagged ambiguities

- **decision** carries three meanings and all three stay — this file records that they coexist, it
  does not resolve them by renaming anything:
  - `docs/decisions.md`: "A **decision** is a control-flow choice the methodology makes" — the
    registry in `decisions/registry.json`, run by `scripts/decide.sh`, with a declared verdict
    vocabulary. (Quoted verbatim here, not paraphrased — this is the newest and most-guarded of
    the three homes.)
  - `review-followups`: an **owner decision** — a follow-up only the repo owner can settle
    (`"owner": true` in a migrated repo's `migration/report.json`; `scripts/followups.py`'s French
    output calls this "décisions propriétaire").
  - `triage-backlog` / `review-followups`: **close by decision** — the documented "not pursued" outcome
    for an issue that fails the filing bar on review.

  When the bare word would read the wrong way, qualify it: *registry decision*, *owner decision*,
  *close by decision*. Renaming any of these is a separate decision for the owner, not a side
  effect of this glossary.

- **backlog** names two different things:
  - `docs/backlog.md` — the kit's own trigger-tagged YAGNI debts, read by `followups.py --backlog`.
  - the GitHub issue queue — what `triage-backlog` and `auto-dev` operate on.

  Prefer *kit backlog* and *issue queue* when both are in play in the same sentence.
