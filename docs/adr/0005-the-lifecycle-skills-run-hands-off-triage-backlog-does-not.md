---
id: 5
title: The lifecycle skills run hands-off; triage-backlog does not
status: accepted
date: 2026-08-31
tags:
- lifecycle
- autonomy
code_refs:
- path: skills/create-issue/SKILL.md
- path: skills/triage-backlog/SKILL.md
---

# The lifecycle skills run hands-off; triage-backlog does not

## Context and Problem Statement

`create-issue`, `implement-issue` and `merge-pr` run unattended inside an `auto-dev` fleet, where a
skill that stops to ask a question stalls a worker nobody is watching. `triage-backlog` is the same
shape of skill with a different irreversible act: deciding a piece of work will not be done.
(Context lifted from the "Autonomy contract" section each of those SKILL.md files carries.)

## Considered Options

- One autonomy rule for every lifecycle skill — all hands-off.
- One rule the other way — every skill confirms before acting.
- Hands-off by default, with `triage-backlog` explicitly exempted.

## Decision Outcome

Each lifecycle skill carries an explicit **Autonomy contract** section: `create-issue`,
`implement-issue` and `merge-pr` pick the reasonable default, state the assumption and keep going,
stopping only for a genuine blocker — because their irreversible act is gated by something objective
(CI says yes) — while `triage-backlog` proposes everything and executes only what the owner
confirms, because closing an issue is a judgement about intent and intent belongs to the owner.

## Consequences

A fleet cannot drain its own backlog by declining it, which is the failure the exemption exists to
prevent. The cost is that `triage-backlog` cannot be run unattended, so `auto-dev` never dispatches
it.
