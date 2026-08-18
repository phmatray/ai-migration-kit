---
name: systematic-debugging
description: Use BEFORE proposing or applying any fix when something is already broken or behaving unexpectedly — a bug, failing or flaky test, crash, exception, stack trace, regression, build break, or integration failure — i.e. any time guessing at a fix is tempting. Enforces finding the root cause first so the fix addresses the real problem instead of masking a symptom. Not for writing new code, adding features or error handling, refactoring code that works, setting up CI/tooling, or reviewing code that already works.
license: MIT
compatibility: >-
  Harness-agnostic: no tools, MCP servers or repo state required. Ported from the superpowers skill
  of the same name, reworded for trigger precision and decoupled from that suite's other skills.
metadata:
  author: Philippe Matray
  suite: ai-migration-kit
---

# Systematic Debugging

## Overview

When something breaks, the fastest-feeling move is to change the line where the error appears and re-run. That instinct is usually wrong: it fixes where the problem *surfaces*, not where it *starts*. The symptom goes quiet, the cause stays, and it resurfaces later — often somewhere harder to see.

**Core principle:** Find the root cause before changing code. A fix you can't explain is a guess, and guesses tend to add new variables rather than remove the broken one.

This skill is a process for not-guessing. It is most valuable exactly when guessing is most tempting — under time pressure, when a quick patch looks obvious, or after a fix has already failed.

## The Iron Law

```
NO FIX WITHOUT A ROOT CAUSE YOU CAN EXPLAIN
```

If you cannot say *"this fails because X, and here is the evidence,"* you are not ready to propose a fix. Finish Phase 1 first.

This isn't bureaucracy — it's the one rule that separates debugging from thrashing. Every shortcut around it trades a few minutes now for a latent bug and a longer second session later.

## When to use

Use for any technical issue: failing tests, production bugs, unexpected behavior, performance problems, build failures, integration issues, flaky tests.

The process matters **most** in the moments it feels least affordable:

- **Under time pressure** — an outage or a deadline makes guessing feel responsible. It isn't; a wrong guess extends the outage and you still have to debug afterward.
- **When "just one quick fix" looks obvious** — the obvious fix is often the symptom. Spend two minutes confirming the cause before you spend them patching.
- **After a fix didn't work** — a failed fix is data, not a reason to pile on a second guess.
- **When you don't fully understand the issue** — "I don't understand X yet" is the correct state to be in before Phase 1, not something to paper over.

"It's a simple bug" is not an exception — simple bugs have root causes too, and the process is fast when the bug really is simple.

## The four phases

Complete each phase before moving to the next. The phases exist because skipping one is how guessing sneaks back in.

### Phase 1 — Root cause investigation

Do this *before* touching any code.

1. **Read the error carefully.** The message, the full stack trace, line numbers, file paths, error codes. Errors frequently name the cause outright; skimming past them is how easy bugs become hard ones.
2. **Reproduce it consistently.** What are the exact steps? Does it happen every time? If you can't reproduce it, you can't verify a fix later — so gather more data rather than guessing in the dark.
3. **Check recent changes.** `git diff`, recent commits, new dependencies, config or environment changes. "It worked before" means *something* changed — find what.
4. **Gather evidence at component boundaries.** When the system has multiple layers (CI → build → sign, request → service → DB), don't guess which layer is at fault. Instrument each boundary — log what enters and exits each component — run once, and let the evidence point to the failing layer. Then investigate *that* layer.
5. **Trace the data flow.** When the error is deep in the call stack, trace the bad value backward to where it originates, and fix it at the source. See `root-cause-tracing.md` for the full backward-tracing technique.

You're done with Phase 1 when you can state what is failing and why, with evidence — not a hunch.

### Phase 2 — Pattern analysis

Understand the shape of the problem before you change anything.

1. **Find working examples.** Locate similar code in the same codebase that *does* work. The difference between it and the broken code is your strongest lead.
2. **Read references completely.** If you're following a pattern, library, or reference implementation, read all of it — not the first plausible snippet. Partial understanding is where most "mysterious" bugs come from.
3. **List every difference** between working and broken, however small. Resist "that can't matter" — that's often exactly what mattered.
4. **Understand dependencies and assumptions** — what config, environment, or invariants the code relies on.

### Phase 3 — Hypothesis and test

Apply the scientific method so a confirmed cause, not a coincidence, drives the fix.

1. **State one hypothesis, specifically:** "I think X is the root cause because Y." Write it down. Vague hypotheses can't be tested.
2. **Test it minimally** — the smallest change that confirms or refutes it, one variable at a time. Changing several things at once means you won't know which one mattered.
3. **Check the result.** Confirmed → Phase 4. Refuted → form a *new* hypothesis from what you learned; don't stack another guess on top.
4. **When you don't know, say so.** "I don't understand X" is a valid, useful state — research it or ask, rather than pretending and patching.

### Phase 4 — Implementation

Fix the cause you confirmed, and prove it.

1. **Write a failing test first.** The simplest reproduction that fails because of this bug — an automated test where possible, a one-off script otherwise. A test that fails now and passes after is what proves the fix is real rather than coincidental. (Use your project's test-driven-development practice for writing it.)
2. **Make one fix, at the source.** Address the confirmed root cause, one change at a time. No bundled refactors or "while I'm here" improvements — they muddy what actually resolved the bug.
3. **Verify.** The new test passes, no other tests broke, the original issue is actually gone. Confirm the fix worked before claiming it's done.
4. **If the fix fails, stop and re-examine.** Count your attempts. Under three: return to Phase 1 with the new information. **Three or more failed fixes is a signal in itself** — see below.

### When three or more fixes fail: question the architecture

If each fix reveals a new problem somewhere else, or every fix would need "massive refactoring," you are probably not looking at a stubborn bug — you're looking at a wrong design.

Symptoms of this:
- Each fix surfaces new shared state / coupling / breakage in a different place.
- Fixes keep creating new symptoms elsewhere.

Stop fixing and step back to fundamentals: Is this pattern sound? Are we continuing out of inertia? Should we change the design instead of patching it? **Raise this with your human partner before attempting another fix.** This is a wrong-architecture situation, not a failed-hypothesis one, and more patches won't resolve it.

## Bundled techniques

These references in this directory go deeper on specific situations. Read the one that fits:

- **`root-cause-tracing.md`** — trace a bug backward through the call stack to its original trigger (and how to add instrumentation when you can't trace by reading).
- **`defense-in-depth.md`** — after finding the root cause of an invalid-data bug, add validation at every layer so the bug becomes structurally impossible.
- **`condition-based-waiting.md`** — fix flaky/timing-dependent tests by waiting for the actual condition instead of guessing at a delay.
- **`find-polluter.sh`** — bisection script to find which test is leaving behind state that breaks another test.

## Red flags — stop and return to Phase 1

If you catch yourself thinking any of these, you've drifted into guessing:

- "Quick fix for now, investigate later."
- "Let me just try changing X and see."
- "I'll make several changes and run the tests."
- "Skip the test, I'll check it manually."
- "It's probably X, let me fix that." / "I see the problem" (from the symptom alone).
- "I don't fully understand it, but this might work."
- "The reference is long; I'll adapt the pattern from memory."
- Listing fixes before you've traced the data flow.
- "One more attempt" — when you've already tried two or more.

Any of these means: stop, return to Phase 1. (And three-plus failed fixes means question the architecture, above.)

## Signals from your human partner

Your partner often notices you've started guessing before you do. Treat these as a cue to stop and return to Phase 1:

- *"Is that actually happening?"* → you assumed something without verifying it.
- *"Will that show us where it breaks?"* → you should add evidence-gathering first.
- *"Stop guessing."* → you're proposing fixes without understanding.
- *"Think harder about this."* → question fundamentals, not just the symptom.
- *"Are we stuck?"* (frustrated) → the current approach isn't working; change approach, don't repeat it.

## Common rationalizations

Each of these *feels* reasonable in the moment. The right column is why it costs more than it saves.

| In-the-moment excuse | Why it's wrong |
|---|---|
| "Issue is simple, skip the process" | Simple bugs have root causes too — and the process is fast when they're simple. |
| "Emergency, no time for process" | Systematic debugging is *faster* than guess-and-check thrashing, and doesn't leave latent bugs in an already-bad situation. |
| "Just try this first, then investigate" | The first fix sets the direction. A guess first usually means a second debugging session later. |
| "I'll write the test after I confirm the fix" | Without a failing test, you can't tell a real fix from a coincidence. Untested fixes don't stick. |
| "Several fixes at once saves time" | You won't know which change worked, and you risk introducing new bugs you'll later blame on the old one. |
| "Reference is too long, I'll adapt it" | Partial understanding is the most common source of these bugs. Read it fully. |
| "I see the problem, let me fix it" | Seeing the *symptom* isn't understanding the *cause*. |
| "One more fix attempt" (after 2+) | Three-plus failures points at the architecture, not the bug. Question the design instead of patching again. |

## Quick reference

| Phase | Activities | Done when |
|---|---|---|
| **1. Root cause** | Read errors, reproduce, check recent changes, instrument boundaries, trace data flow | You can state what fails and *why*, with evidence |
| **2. Pattern** | Find working examples, read references fully, list differences, map dependencies | You know what's different between working and broken |
| **3. Hypothesis** | State one hypothesis, test it minimally | It's confirmed — or refuted and you have a new one |
| **4. Implementation** | Failing test, single fix at the source, verify | Bug is gone, the new test passes, nothing else broke |

## When investigation finds no single root cause

Sometimes thorough investigation shows the issue really is environmental, timing-dependent, or external. If so:

1. You've completed the process — that's a legitimate outcome, not a failure.
2. Document what you investigated and ruled out.
3. Implement appropriate handling (retry, timeout, clear error message, condition-based waiting).
4. Add logging/monitoring so a future occurrence leaves evidence.

Be honest with yourself here, though: most "there's no root cause" conclusions are really *"I stopped investigating too early."* Make sure you actually traced the data flow before reaching for this.

## Why this pays off

Guessing feels faster because the first edit is quick. But each unconfirmed change adds a variable instead of removing the broken one, so failed guesses compound — and a symptom patch leaves the real bug to resurface later, usually at a worse time. Finding the cause first is what makes a fix stick, keeps it from spawning new bugs, and leaves the code better understood than before. Done right, the bug doesn't come back and similar bugs get easier to spot.
