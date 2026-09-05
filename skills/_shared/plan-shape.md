# Shared Plan Shape: an implementation plan an executor can run cold

Ported from obra/superpowers `writing-plans` (MIT, © Jesse Vincent), narrowed in two ways: the plan
lives in the **issue body** rather than in a `docs/…/plans/` file, because GitHub's task-list
progress meter counts checkboxes in the body and `implement-issue` reads the plan straight out of
it; and the executor the header note names is the kit's own `implement-issue` (Step 3 picks
subagent-per-task or inline), not the source's two skills. This file is the one home for the shape —
`create-issue` Step 6 writes to it and `implement-issue` Step 2 reads by it, and neither restates it
(#324).

The premise is the source's: write the plan **assuming the engineer has zero context for the
codebase and questionable taste**. Which files to touch for each task, the code, the test, the
command that proves it, the docs they might need — bite-sized, DRY, YAGNI, TDD, one commit per
task. Assume a skilled developer who knows almost nothing about this toolset or problem domain and
does not know good test design well.

## Header note

The plan opens with this line, **verbatim** — it is what a fresh session reads first:

> **For agentic workers:** execute this plan task-by-task with `implement-issue` (subagent-per-task for broad plans, inline for small ones). Steps use checkbox (`- [ ]`) syntax for tracking.

Issues filed before #324 carry an older note naming the plugin's executors. Both execute unchanged:
`implement-issue` Step 2 anchors on the `## 🛠️ Implementation plan` heading, never on the note
(`tests/skills/test.sh` case SP2 pins that with a fixture of each).

## Heading and placement

The plan is a flat, **visible** section under the exact heading `## 🛠️ Implementation plan` —
`implement-issue` anchors on that phrase. Never inside a `<details>` (the progress meter may stop
counting) and never flattened into `- **Files:**` / `- **Test:**` prose (the checkboxes are what
GitHub renders as live, tickable progress).

## Preamble

Directly under the header note, in this order:

- **Goal:** one sentence — what this builds.
- **Architecture:** two or three sentences on the approach.
- **Tech stack:** the key technologies and libraries.
- **Seams under test:** copied verbatim from the Spec's `### Testing decisions` heading
  ([`test-seams.md`](test-seams.md)) — the public boundary each test observes through.
- **Global Constraints:** the project-wide requirements every task implicitly inherits, one line
  each with exact values — version floors, dependency limits, the architecture invariants from the
  repo profile's *Architecture grain*, the commit identity from *Commit identity*, build and
  naming rules, the per-task test command and the before-ready command.

## File structure first, then tasks

Before defining tasks, map which files are created or modified and what each is responsible for —
this is where decomposition is locked in. Units with clear boundaries and one responsibility each;
files that change together live together; split by responsibility, not by technical layer. In an
existing codebase follow the established patterns — do not restructure unilaterally, but if a file
the plan modifies has grown unwieldy, a split is a reasonable task.

**Right-sizing.** A task is the smallest unit that carries its own test cycle and is worth a fresh
reviewer's gate. Fold setup, configuration, scaffolding and documentation into the task whose
deliverable needs them; split only where a reviewer could meaningfully reject one task while
approving its neighbour. Each task ends with an independently testable deliverable, and the tasks
form a chain — later ones build on earlier ones, which is why `implement-issue` never runs them in
parallel.

**Bite-sized steps.** Each step is one action of two to five minutes: write the failing test — run
it and watch it fail — write the minimal code — run it and watch it pass — commit.

## The task block

````markdown
### Task N: <component name>

**Files:** create `exact/path/to/new.py`; modify `exact/path/to/existing.py:123-145`; test `tests/exact/path/test.py`.

**Interfaces:** consumes `<what this task uses from earlier tasks — exact signatures>`; produces `<what later tasks rely on — exact names, parameter and return types>`.

- [ ] **Step 1:** Write the failing test in `tests/exact/path/test.py` (seam: `<the seam it crosses>`) — assert `<the behaviour>`.
- [ ] **Step 2:** Run `<the per-task test command>` → FAIL (`<the expected reason: symbol not found, assertion on X>`).
- [ ] **Step 3:** Implement `<the minimal change>` in `exact/path/to/new.py`.
- [ ] **Step 4:** Re-run `<the per-task test command>` → PASS.
- [ ] **Step 5:** Commit: `<type>(<scope>): <subject>`.
````

- **Files** and **Interfaces** are exact. A task's implementer sees only their own task; the
  Interfaces line is how they learn the names and types neighbouring tasks use.
- **Every step is its own `- [ ]` checkbox.** `implement-issue` ticks them on the live issue as the
  work lands, and `tick-plan.sh` refuses any edit that is not a checkbox flip — so a step that is
  not a checkbox is a step nobody can mark done.
- **Every failing-test step names the seam it crosses**, drawn from the preamble's `Seams under
  test:` line.
- **The final step is the commit message**, verbatim: `implement-issue` commits with it, so git
  history mirrors the plan and the issue.

## No placeholders

Every step contains the actual content an engineer needs. These are **plan failures** — never write
them: "TBD", "TODO", "implement later", "fill in details"; "add appropriate error handling" / "add
validation" / "handle edge cases"; "write tests for the above" without the test; "similar to Task N"
(repeat it — the engineer may read tasks out of order); a step that says what to do without showing
how; a reference to a type, function or file no task defines.

## Commit type

**Pick one Conventional Commits type and use it consistently in both the Global Constraints
preamble's example and every task's final commit-message step — never default either to `docs:`
merely because the plan's diff reads like prose.** Check the Spec's **scope/non-goals** first: only
when *every* touched path is genuinely non-shipped (`docs/`, `.github/`, `README.md`,
`ARCHITECTURE.md`, …) is `docs:`/`ci:` correct. Otherwise — the plan touches anything inside a shipped
directory (`skills/`, `scripts/`, `commands/`, `templates/`, `hooks/`, `requirements.json`) — derive
the type from the issue's own `type` label instead, the same way the repo profile's *PR title
convention* already does: `bug`→`fix`, `enhancement`→`feat`. `scripts/release-title-gate.sh`
refuses a non-releasable type on a shipped path regardless of how prose-like the diff looks, and
that check runs the moment the PR is opened — a `docs:` example baked into the plan becomes a red
check on the PR almost immediately, not a late-stage surprise.

## Self-review

After writing the whole plan, look at the Spec with fresh eyes and check the plan against it — a
checklist you run yourself, not a sub-agent dispatch:

1. **Spec coverage** — for each requirement and acceptance criterion, point to the task that
   implements it. A requirement with no task gets one.
2. **Placeholder scan** — search for every pattern in *No placeholders*. Fix them.
3. **Name consistency** — do the types, signatures and paths later tasks use match what earlier
   tasks defined? `clearLayers()` in Task 3 and `clearFullLayers()` in Task 7 is a bug.

Fix inline; no second pass.

## Consumers

- `skills/create-issue/SKILL.md` — Step 6 writes every filed plan to this shape, and its decompose branch writes one per child
- `skills/implement-issue/SKILL.md` — Step 2 parses the plan by this shape; Step 6 commits with each task's final step
- `docs/methodology.md` — cites this shape describing what create-issue's Step 6 writes
