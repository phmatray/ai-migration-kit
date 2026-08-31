# Shared Brainstorm & Spec Doctrine: from a raw idea to a design someone else can build

Ported from obra/superpowers `brainstorming` (MIT, © Jesse Vincent), with one deliberate narrowing:
that skill is a **dialogue** — one question per message, an approval gate before every
implementation step, a spec the human reviews before a plan is written. This kit runs the same
process **hands-off, in one shot**: `create-issue` files into an empty room, `merge-pr` Step 6 and
the `auto-dev` workers file issues with nobody watching, and a question asked there is the never-wait
failure (#187). So every point where the source stops to ask, this doctrine says *pick the most
reasonable default, state it, keep going* — the `**Assumptions**` note at the end of each half is
where those picks are recorded, and `--grill` ([`grilling.md`](grilling.md)) is the one sanctioned
exception. This file is the one home for the doctrine; `create-issue` Step 5 links here instead of
restating it, and the kit's own CI (`tests/skills/test.sh`) refuses a plugin invocation (the colon form) in
any shipped skill so the two sources of truth cannot come back (#324).

## Before either half: read the tree, then size the idea

- **Explore the project context first** — files, docs, recent commits, the accepted ADRs for the
  idea's area (the consuming skill says how). Cite what you found; an approach argued from the
  README's roadmap or a real code path is worth three argued from the idea alone.
- **Assess scope before refining detail.** If the request describes several *independent*
  subsystems ("chat, file storage, billing, and analytics"), say so now rather than spending the
  brainstorm on one corner of it — the answer is decomposition (in `create-issue`, the decompose
  branch of Step 6), each piece getting its own brainstorm → spec → plan.
- **Do not interrogate.** The source asks the questions that matter one at a time; here every
  question you would have asked becomes a stated assumption with the answer you would have
  recommended. Facts are never assumptions: anything you could look up, you look up.

## 🧠 Brainstorm — focused, not a wall of text

1. **Problem / context.** What need, for whom, what already exists — with citations (a README
   section, a roadmap line, a file and symbol, a measured number). If the evidence already makes a
   decision, state it as a finding here; it is not an open question.
2. **Approaches — two or three, with honest trade-offs.** Each one genuinely different, each one
   YAGNI-pruned (remove every feature the need does not require, from every option). Name what each
   costs, not only what it buys; a "both" option is usually two sources of truth wearing one name.
3. **Recommendation — one, and why.** Lead with it. It drives the Spec and the plan, so the reasoning
   has to be the kind a reader can disagree with: *X because Y, at the cost of Z*.
4. **Assumptions.** The defaults picked where the source would have asked: which surface, which
   default ships, whether compatibility may break, where the scope boundary sits.

**Design for isolation and clarity.** Break the system into units that each have one clear purpose,
communicate through well-defined interfaces, and can be understood and tested on their own. For
each unit you should be able to say what it does, how it is used and what it depends on; if a
reader cannot understand a unit without its internals, or the internals cannot change without
breaking consumers, the boundaries need work. Smaller, well-bounded units are also easier to
implement reliably — an executor reasons best about what it can hold in context at once.

**In an existing codebase, follow its patterns.** Explore the current structure before proposing
changes. Where existing code has a problem that affects *this* work (a file grown too large, a
tangled responsibility), include the targeted improvement the way a good developer improves the
code they are working in — and propose no unrelated refactoring.

## 📋 Spec — the formal design for the recommended approach

The Spec is what a stranger builds from, so it is written to be executed, not admired:

- **Goal** — one sentence; **Scope** and **Non-goals** — what the change touches and what a
  reviewer might expect and must not find.
- **Public surface or behaviour** — the interface, command, output or flow that changes, stated
  precisely enough to test against.
- **Key types / files** — exact paths and names; **Validation rules**; **Edge cases**.
- **Assumptions** — the Spec's own, distinct from the brainstorm's: defaults chosen while designing.
- A **mermaid diagram** where the design has *shape* — a state machine, a context map, an aggregate,
  a pipeline. Use it where it clarifies; do not decorate.
- **The contract the Spec ends with**: `### Acceptance criteria` (numbered, each independently
  verifiable without reading the diff), `### Testing decisions` (the seams under test, prior art, what
  a good test looks like — per [`test-seams.md`](test-seams.md)) and `### Out of scope`. The exact
  block, and the reason the criteria are a numbered list and never checkboxes, are in
  `create-issue` Step 5, which owns that shape because it is what the issue body's checkbox count
  depends on.

**Self-review before it leaves your hands** (the source's spec review, kept verbatim in spirit —
fix inline, no second pass):

1. **Placeholder scan** — any "TBD", "TODO", incomplete section or vague requirement? Fix it.
2. **Internal consistency** — do sections contradict each other? Does the architecture match the
   behaviour described?
3. **Scope check** — is this focused enough for a single implementation plan, or does it need
   decomposing?
4. **Ambiguity check** — could a requirement be read two ways? Pick one and make it explicit.

The source ends here with a human reviewing the written spec. This kit does not: the Spec goes
straight into [`plan-shape.md`](plan-shape.md)'s plan, and the human reads both on the filed issue —
which is why the Assumptions notes exist, and why a contradiction with an accepted ADR is a finding
the brainstorm states rather than a decision it makes silently.

## Consumers

- `skills/create-issue/SKILL.md` — Step 5 writes the 🧠 Brainstorm and 📋 Spec sections of every filed issue to this shape
