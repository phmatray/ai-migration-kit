---
id: 7
title: Workers are in-process sub-agents, never claude -p
status: proposed
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

`skills/auto-dev/SKILL.md` and `commands/auto-dev-worker.md` still describe the `claude -p` shape and
must be rewritten before this record can move from `proposed` to `accepted`; that is why the status
is `proposed` and why `search_adrs` filtered to `accepted` correctly will not return it yet.
