# Shared TDD Loop: red before green, one slice at a time

Two ports in one file, both MIT: the loop and its verification discipline from obra/superpowers
`test-driven-development` and `verification-before-completion` (© Jesse Vincent); what a good test
is and where a mock belongs from mattpocock/skills `engineering/tdd` (`tests.md`, `mocking.md`).
This file is the one home for the loop — `implement-issue` Step 6 links here for every task instead
of restating it, and [`test-seams.md`](test-seams.md) (already ported from the same `tdd` skill)
owns the seam doctrine and the anti-patterns, which this file points at rather than repeats (#324).

The source's premise, kept whole: **if you did not watch the test fail, you do not know that it
tests the right thing.** Everything below follows from that sentence.

## The loop

Each plan task is one or more passes through this cycle, in this order, with nothing skipped:

1. **RED — write one failing test** that shows what should happen. One behaviour, a name that
   describes it, real code under it (a double only where [`test-seams.md`](test-seams.md)
   §*Mock at boundaries only* allows one). It crosses the seam the plan named for this task.
2. **Verify RED — run it and read the output.** It must *fail*, not *error*: the message is the one
   you expected, and the cause is the missing behaviour, not a typo. A test that passes at this
   point is testing behaviour that already exists — fix the test. A test that errors is not yet a
   test — fix the error and re-run until it fails correctly.
3. **GREEN — write the minimal code** that makes that test pass. Not the feature you can see coming,
   not a cleanup of the code next to it, not an option nobody asked for. YAGNI applies to every
   line.
4. **Verify GREEN — run it and read the output.** This test passes, every other test still passes,
   and the output is pristine — no new warnings, no stray errors. If it fails, fix the code, not the
   test; if another test fails, fix that now.
5. **Commit** with the message the plan's final step gives, then take the next slice.

**Refactoring is not part of the loop.** It belongs to the review stage — `implement-issue` Step 7's
`code-review` pass over the whole branch — not to the red → green cycle of a single task. Inside the
loop, a passing test is the signal to move on, not to tidy.

## The rules

- **Red before green.** No production code without a failing test that demands it. Code written
  before its test is deleted and re-implemented from the test — not kept "as reference", not adapted
  while the test is written after it. A test written after the code passes immediately, which
  proves nothing: it may test the wrong thing, or the implementation instead of the behaviour, and
  you never watched it catch the bug.
- **One slice at a time.** One seam, one test, one minimal implementation per cycle — a tracer
  bullet that responds to what the last cycle taught you. Writing every test first and then all the
  code is the horizontal-slicing anti-pattern in `test-seams.md`.
- **A bug fix starts with the test that reproduces it.** Then the loop; the test proves the fix and
  stands guard against the regression. Never fix a bug without one.
- **The exceptions are the plan's to grant, not yours.** Generated code, a throwaway prototype, a
  configuration file: a plan that wants one of these untested says so in its task block. "Skip TDD
  just this once" from inside the loop is the rationalization the source names first.

## What a good test is

Tests verify **behaviour through public interfaces**, not implementation details. The code can
change entirely; the tests should not. A good test reads like a specification — *"user can checkout
with valid cart"* says exactly what capability exists — and it survives refactors because it does
not care about internal structure.

- **Describes WHAT, not HOW.** The name states the behaviour; the body uses the public API only;
  one logical assertion per test. *"checkout calls paymentService.process"* is a test of how, and
  it breaks the day the collaborator is renamed while the behaviour stands.
- **Verifies through the interface, never around it.** *createUser makes user retrievable* asserts
  through `getUser(id)`; a `SELECT` against the table behind it is a side channel that couples the
  test to storage the interface exists to hide.
- **The expected value comes from an independent source of truth** — a hand-derived literal, a
  worked example, the spec, a fixture checked into the tree. An expectation recomputed the way the
  code computes it (`items.reduce(...)` on both sides, a snapshot derived by the same helper) passes
  by construction and can never disagree with a bug.
- **Name the break before writing the body.** What production change should make this test fail —
  and is it a bug, or a decision? A test only a deliberate decision can fail (a constant's value,
  exact wording, private structure) is a change detector: it fires on redesign and sleeps through
  bugs. Test the behaviour that depends on the decision instead.
- **Behaviour, not text.** Asserting that a script or a document contains an exact line proves only
  that the source is the source. Run the artifact against controlled inputs and assert outputs, side
  effects or exit codes. Where this kit pins prose (a link that must resolve, a credit line, an
  invocation that must be absent), it says why in the case's comment — the defect *is* the committed
  text — and it reads the value it checks out of the doctrine file rather than re-spelling it.

## Doubles inside the loop

*Where* a double is allowed — system boundaries only, never your own modules — is
[`test-seams.md`](test-seams.md) §*Mock at boundaries only*, and it is not repeated here. What
follows is how a double behaves once that rule has allowed it:

- **A mock earns no assertions.** An assertion on the mock passes when the mock is present and
  fails when it is absent; it says nothing about the component. Assert the real component's
  behaviour, or unmock it.
- **Learn a dependency's side effects before replacing it**, and mock the slow or external level
  *below* the ones the test depends on — a mock that swallows the config write the code under test
  later reads passes while integration breaks. When unsure, run the test against the real thing
  first and observe what actually has to happen.
- **Doubles are specific and complete.** When arguments, call counts or ordering are part of the
  contract, assert them; a fake that accepts anything verifies nothing. Mirror the real structure
  with all its documented fields, not only the ones this test reads (`test-seams.md`'s
  `tests/survey/test.sh` example is this rule at work).
- **Design the boundary to be mockable.** Pass external dependencies in rather than constructing
  them inside; prefer one specific function per external operation (`getUser`, `createOrder`) over
  a generic fetcher whose mock needs conditional logic to answer.
- **Test-only code lives in test utilities**, never as a `destroy()` on a production class. When
  mock setup outgrows the test, or the mock keeps missing methods the real component has, switch to
  an integration test with real components.

For the seam vocabulary — what a seam is, choosing seams before tests, where a double may stand,
the three anti-patterns (implementation-coupled, tautological, horizontal slicing) — read
[`test-seams.md`](test-seams.md); none of it is repeated here.

## Evidence before claims

No completion claim without fresh verification evidence in the same breath. Before saying a test
passes, a build succeeds, a bug is fixed, or a task is done: **identify** the command that proves
it, **run** it in full, **read** the whole output and the exit code, and only then **say** it — with
the evidence. "Should pass", "looks correct", a previous run, a sub-agent's own report of success:
none of these is evidence. A regression test is proven by red → green, not by passing once; a
sub-agent's work is proven by the diff it left, not by its summary. This is why `implement-issue`
ticks a box, commits, or flips a PR to ready only on output it has seen (its Autonomy contract),
and why a resolved merge is re-built and re-tested on the merged tree.

## Consumers

- `skills/implement-issue/SKILL.md` — Step 6 runs every task through this loop; its Autonomy contract states the same evidence rule in its own words
