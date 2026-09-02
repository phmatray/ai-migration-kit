---
id: 7
title: Workers are in-process sub-agents, never claude -p
status: accepted
date: 2026-08-31
tags:
- auto-dev
- harness
code_refs:
- path: skills/auto-dev/SKILL.md
- path: commands/auto-dev-worker.md
---

# Workers are in-process sub-agents, never claude -p

## Context and Problem Statement

`auto-dev` keeps N issues in flight by dispatching a worker per issue, and today it dispatches them
as one-shot `claude -p` processes: a worker that ends its turn is killed, cannot be messaged
mid-flight, and a correction means re-dispatching a fresh session with a tail prompt. In-process
sub-agents are addressable, resumable and observable from the supervisor. (Recorded from the owner's
rule of 2026-08-31, the 2.0 breaking change; the opposite is still written into
`commands/auto-dev-worker.md` and `skills/auto-dev/SKILL.md` as of this record.)

## Considered Options

- One-shot `claude -p` worker processes, as today.
- In-process background sub-agents the supervisor can message and resume.
- A mix: sub-agents for phase 1, `claude -p` for the merge phase.

## Decision Outcome

Workers are in-process background sub-agents; `auto-dev` never shells out to `claude -p`, so a
supervisor can message a worker mid-flight, a correction is a message rather than a re-dispatch, and
a worker that stalls is a live agent to be asked rather than a dead process to be re-run.

## Consequences

`skills/auto-dev/SKILL.md` and `commands/auto-dev-worker.md` were rewritten to the sub-agent shape
by #314 (PR #328, the 2.0 breaking change): a worker is dispatched through the Agent tool with a
`model` parameter, can be messaged with `SendMessage`, and its final message is its report. Neither
file describes `claude -p` any more — `tests/auto-dev-never-wait/test.sh` pins the worker prompt —
which is what moved this record from `proposed` to `accepted` (2026-09-02). The cost: the trigger
bench `evals/run_all.py`, which spawns real `claude -p` processes to measure descriptions, can never
run inside a fleet and stays an owner-run step.
