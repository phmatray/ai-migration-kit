---
id: 9
title: Interaction modes
status: rejected
date: 2026-07-23
tags:
- out-of-scope
- arbor
parent: Architectural Decision Records
nav_order: 9
---

# Interaction modes

## Context and Problem Statement

Arbor exposes a `ui.interaction_mode` setting — `auto`, `direction`, `review`, `collaborative` —
that decides how much the operator is asked before the agent acts. The 2026-07-23 jobs review
(`reviews/2026-07-23-jobs/`) proposed the same knob for the kit: one configuration value naming how
autonomous a run should be, read by every phase.

The request recurs under several names because the underlying wish is common and reasonable — an
autonomy level, a supervision setting, a `--interactive` / `--yolo` pair, a confirmation policy, a
human-in-the-loop mode. Each arrives as "the kit should let me choose how much it asks me".

Recorded as French prose in `docs/backlog.md` §Non-adoptions until this ADR replaced it.

## Considered Options

- A `ui.interaction_mode` configuration value with four levels, read by every phase.
- A per-invocation flag with the same four levels.
- Decline: the entry points already differ by autonomy, and that is the axis.

## Decision Outcome

Not pursued by decision (2026-07-23): the kit's **scope variants already are** the interaction
modes, and they are better ones because each is a different job rather than the same job with a
different confirmation policy. `/migrate-assess` is read-only, `/migrate` runs the pipeline,
`/migrate-verify` re-runs the final gate; `triage-backlog` proposes and executes only what the owner
confirms, while the lifecycle skills run hands-off (ADR-0005). Adding a fourth orthogonal
concept on top of those would mean every phase reading a mode it mostly ignores, and two ways to
express "ask me first" that can disagree.

## Consequences

Autonomy is chosen by picking an entry point, not by setting a value — so the choice is visible in
what the user typed, and a skill can never be half-way between two policies.

The one condition that reopens this: a genuine need the entry points **cannot** express — a level of
supervision that is not "which job am I running" but "how much do I trust this particular run" —
demonstrated by a case the existing variants leave with no answer. Reopening is a fresh ADR plus
`set_status deprecated` here, never an edit in place.

## Prior requests

- `reviews/2026-07-23-jobs/` — "Modes d'interaction (`ui.interaction_mode` auto/direction/review/
  collaborative)": a configurable autonomy level, supervision setting, interactive/yolo flag pair or
  human-in-the-loop confirmation policy, read by every phase (2026-07-23).
