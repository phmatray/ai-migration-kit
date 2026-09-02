---
id: 8
title: Idea-tree search
status: rejected
date: 2026-07-23
tags:
- out-of-scope
- arbor
parent: Architectural Decision Records
nav_order: 8
---

# Idea-tree search

## Context and Problem Statement

The 2026-07-23 jobs review (`reviews/2026-07-23-jobs/`) read the kit through the Arbor (RUC-NLPIR)
lens and asked, in one breath, for two different things. The kit took the first: Arbor's safety
belts — resume, the convergence guard, measured chronology, contractual backpropagation — shipped in
v1.8.0. The second was Arbor's steering wheel: a **multi-hypothesis idea tree**, where the agent
branches several candidate approaches, scores them against a metric, and keeps exploring the
promising ones.

It keeps being asked because the pitch is genuinely appealing and the vocabulary is fluid: idea
tree, hypothesis tree, tree-of-thought, branch-and-score, multi-hypothesis exploration, beam search
over approaches. Under any of those names it sounds like a strict upgrade — the kit "only" walks one
path, so surely walking several is better.

Recorded as French prose in `docs/backlog.md` §Non-adoptions until this ADR replaced it.

## Considered Options

- Adopt the idea tree: branch on approach, score, prune, keep the best.
- Adopt it only in the assessment phase, where the destination is genuinely open.
- Decline it, and say once, durably, why.

## Decision Outcome

Not pursued by decision (2026-07-23): Arbor explores an **open** space — a metric to maximise, the
best solution unknown — while the kit executes a **known path to a binary destination** (build
green, tests green, production verified). Grafting exploration onto that destroys the property that
makes the kit worth running: deterministic, reproducible, in measured minutes. A migration that
branches is a migration whose cost and outcome nobody can quote in advance, and the second option —
"only in assessment" — is the same trade with a smaller blast radius rather than a different one,
since the assessment's output is the plan every later phase is checked against.

## Consequences

Every phase stays single-path, and a phase that cannot reach its gate stops and says so rather than
trying a sibling approach — the failure is loud instead of expensive.

The one condition that reopens this: **the kit starts optimising an open metric** — performance,
bundle size, cost — where there is no binary gate to reach and exploration therefore pays for
itself. Reopening is a fresh ADR plus `set_status deprecated` on this one, never an edit in place.
"A migration would probably be better with it" is not that condition, and neither is a new name for
the same mechanism.

## Prior requests

- `reviews/2026-07-23-jobs/` — "Arbre d'hypothèses / recherche multi-hypothèses (Idea Tree)":
  multi-hypothesis tree search that branches candidate approaches, scores them and explores an open
  solution space; also asked for as tree-of-thought, branch-and-score, or beam search over
  approaches (2026-07-23).
