# Build a Feedback Loop

> Ported from [mattpocock/skills](https://github.com/mattpocock/skills) (MIT), `engineering/diagnosing-bugs`,
> and adapted to this skill's four-phase structure. The ladder, the tighten pass, the reproduction-rate
> rule and the completion criterion are Matt Pocock's; the framing against the Iron Law is the kit's.

## Overview

Phase 1 asks for a root cause you can explain, with evidence. **A feedback loop is what produces that
evidence.** It is one command you can run that goes red on *this* bug and green once it is fixed —
and everything the rest of this skill does (bisecting, hypothesis-testing, instrumenting, proving the
fix) is mechanical once you have one. Without it, no amount of reading code will save you: you are
building a theory nothing can refute, which is guessing with extra steps.

**Core principle:** Spend disproportionate effort here. Be aggressive, be creative, refuse to give up.
Build the right loop and the bug is most of the way fixed.

## 1. Ways to construct one, in roughly this order

Each rung reaches a deeper seam than the last and costs more to build. Take the shallowest one that
can actually go red on the reported symptom.

1. **Failing test** — at whatever seam reaches the bug: unit, integration, or e2e. Cheapest loop there is, and it becomes the regression test in Phase 4.
2. **Curl / HTTP script** — against a running dev server; reaches the request/response boundary without a test harness.
3. **CLI invocation with a fixture input**, diffing stdout against a known-good snapshot; reaches the whole program as a user runs it.
4. **Headless browser script** (Playwright / Puppeteer) driving the UI and asserting on DOM, console or network; reaches bugs that only exist in the browser.
5. **Replay a captured trace** — save a real request, payload or event log to disk and replay it through the code path in isolation; reaches bugs that need production-shaped data.
6. **Throwaway harness** — a minimal subset of the system (one service, mocked deps) that hits the bug's code path in a single function call; reaches code with no usable test seam.
7. **Property / fuzz loop** — for "sometimes wrong output", run a thousand generated inputs and look for the failure mode; reaches bugs whose trigger you cannot name yet.
8. **Bisection harness** — when the bug appeared between two known states (commit, dataset, version), automate "boot at state X, check, repeat" so `git bisect run` can consume it; reaches *when* over *why*.
9. **Differential loop** — run the same input through old-vs-new (or two configs) and diff the outputs; reaches regressions where neither side is obviously wrong on its own.
10. **HITL bash script** — the last resort. If a human genuinely must click, drive *them* with [`scripts/hitl-loop.template.sh`](scripts/hitl-loop.template.sh) so the loop is still structured and its captured output still feeds back to you.

## 2. Tighten the loop

Treat the loop as a product. Once you have *a* loop, make it better before you use it:

- **Faster?** Cache setup, skip unrelated init, narrow the test scope.
- **Sharper?** Assert on the specific symptom, not "it didn't crash".
- **More deterministic?** Pin the clock, seed the RNG, isolate the filesystem, freeze the network.

The bar: **seconds, one specific assertion, the same verdict every run.** A 30-second flaky loop is
barely better than no loop; a 2-second deterministic one is a different tool entirely.

## 3. Non-deterministic bugs: raise the rate, don't chase a clean repro

The goal is not "find a reproduction that always fires" — for a race you may never get one. The goal
is a **higher reproduction rate**: loop the trigger 100×, parallelise it, add load, narrow the timing
window, inject sleeps at the suspected seam.

**A 50 % flake is debuggable; a 1 % flake is not.** Keep raising the rate until the loop tells you
something within one run, then treat that rate as the loop's determinism (say what it is: "red on
roughly 6 of 10 runs at `-j8`").

## 4. When you genuinely cannot build one

Stop and say so, explicitly. Do **not** proceed to hypothesise without a loop — that is the exact
failure this skill exists to prevent, and doing it after an honest attempt is no better than doing it
first.

- **List what you tried** — which rungs of the ladder, and what blocked each one.
- **Ask for one of:** access to an environment that reproduces it; a redacted captured artifact (HAR file, log dump, core dump, screen recording with timestamps); or permission to add temporary instrumentation in the environment where it happens.

"I could not build a loop, here is what I tried and what I need" is a legitimate, useful outcome.
A confident theory with nothing behind it is not.

## 5. Completion criterion — a tight loop that goes red

Phase 1 is done when you can name **one command you have already run at least once** — show the
invocation and its (redacted) output — and that command is:

- [ ] **Red-capable** — it drives the actual bug code path and asserts the **user's exact symptom**, so it goes red on this bug and green once it is fixed. Not "runs without erroring": it must be able to catch *this specific* bug.
- [ ] **Deterministic** — the same verdict every run. (For flaky bugs: a pinned, stated reproduction rate high enough to debug against, per §3.)
- [ ] **Fast** — seconds, not minutes.
- [ ] **Agent-runnable** — you can run it unattended; a human enters the loop only through `scripts/hitl-loop.template.sh`.

**No red-capable command, no Phase 2.** If you catch yourself reading code to build a theory before
this command exists, that is the drift — stop and come back here.

## 6. Redact

This whole phase has you *show* commands, outputs and captured artifacts. **Replace every secret with
`<REDACTED>` before showing it.** Build loops against environment variables so credentials stay in the
environment rather than in the transcript; captured artifacts (HAR files especially) carry auth
headers, so quote only the lines that carry the signal.

If the redacted output is not enough to diagnose the bug, say so and ask — do not paste the
unredacted version.
