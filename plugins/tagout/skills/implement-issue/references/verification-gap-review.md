# The Verification axis: would a test fail if this broke where it is used?

> **Ported from [BMAD-METHOD](https://github.com/bmad-code-org/BMAD-METHOD) (MIT)** — the
> `verification-gap` review layer of `bmad-build`, condensed to one brief for a sub-agent dispatched
> from `implement-issue` Step 7 alongside the Standards and Spec axes.

The task loop verifies each task by *its own* filtered test, written at *its own* seam. What nothing
in Step 6 asks is whether the change is protected **where it is consumed**: a helper's test can cover
a branch that every real caller skips, a payload change can be asserted nowhere a consumer reads it,
and a test can exist yet never run. This axis asks one question per behavioural change — *if this
broke where it is actually used, would verification fail?* — and reports only the places where the
answer is no.

## What to hand the sub-agent

The same diff file the Spec axis reads (`/tmp/issue-$ISSUE.diff`), plus the **worktree path, for
reading only** — tracing callers and reading tests needs the repository, which the Spec axis does
not. The brief says read-only in those words; the guards are what make a stray write land nowhere
(#477). No Spec: this axis compares the code to its consumers, never to the promise.

## The brief

> You are a reviewer, read-only: do not edit files, write to git, invoke skills or spawn
> sub-agents; return your findings as text. The change is the unified diff at `<diff path>`; the
> repository it applies to is at `<worktree path>`, for reading.
>
> For each part of the diff, first decide whether it changes behaviour — return values, thrown
> errors, caller-visible side effects, observable state, emitted messages. Formatting, comments,
> pure renames and type-only changes do not; skip them. A dependency, toolchain or config change
> counts as behavioural even when no line looks important.
>
> For each behaviour that changed: trace where it is observed — direct callers, registered entry
> points, contract consumers (schemas, events, readers). Stop at the nearest boundary where a test
> would fail, where the consumer does not observe the change, or where the next hop is guesswork.
> Then name the smallest realistic regression that consumer would see (invert the branch, drop the
> default, omit the field), find the test that covers it, and ask whether that regression would make
> an assertion fail.
>
> **Evidence rules.** Read a test before saying what it asserts. Before saying no test exists,
> search the whole repository by symbol and by import — an expected file location is not enough.
> A test counts only if it runs in the normal verification path and an assertion observes the
> changed output; a skipped, disabled or filtered-out test, a mock-only or no-throw check, and a
> source-text assertion do not. Drop any finding you cannot ground; say how far you looked.
>
> Report one block per gap, no severity, no ranking:
>
> - **Changed surface:** the behaviour, `file:line`.
> - **Consumer:** where it is observed, `file:line`.
> - **Existing test evidence:** what the relevant test asserts (`file:line`), or the searches run.
> - **Demonstration:** the regression that would ship undetected, and why the tests you read would
>   not fail.
> - **Disposition:** `patch` — name the test to add, in this repo's own way of testing — or `defer`,
>   with one sentence of why.
>
> A defect you notice while tracing goes under `## Other findings`, description only. With nothing
> to report, output exactly: `No verification gaps found.` **Under 500 words.**

## Disposition — what each finding earns

| Finding | What happens | Where it goes |
|---|---|---|
| `patch` | write the named test **before** the ready-flip; a red one is a bug found, fix it too | a commit on the branch, `test: close verification gap …` |
| `defer` | record it | a `### Follow-ups` bullet in the **PR description** |
| `## Other findings` | triage like a Standards finding — verify at the cited line, one verdict | per Step 7's verdict rule |

A gap finding arrives with its evidence: the brief made the sub-agent read the test and run the
searches it cites. Verify the Demonstration rather than re-deriving the trace.
