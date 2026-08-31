---
id: 10
title: Novelty search
status: rejected
date: 2026-07-23
tags:
- out-of-scope
- arbor
---

# Novelty search

## Context and Problem Statement

Arbor queries alphaXiv to ask whether an idea is academically **novel**, and uses that verdict to
steer its exploration. The 2026-07-23 jobs review (`reviews/2026-07-23-jobs/`) proposed wiring the
same lookup into the kit: before committing to an approach, check the literature and prefer what has
not been published.

It returns under several phrasings — novelty search, a prior-art check, an alphaXiv or arXiv lookup,
"has anyone solved this already", a research-literature gate — and all of them share one unstated
premise: that the kit is choosing between ideas at all.

Recorded as French prose in `docs/backlog.md` §Non-adoptions until this ADR replaced it.

## Considered Options

- Wire an alphaXiv novelty verdict into the assessment phase.
- Keep a weaker version: a literature link in the report, informational only.
- Decline: novelty is not an input to any decision the kit makes.

## Decision Outcome

Not pursued by decision (2026-07-23): an academic novelty verdict **improves no migration**. The
kit's decisions are "does this build", "do these tests pass", "is this API still supported", "what
does the analyzer say" — every one of them answered by running something against this codebase, none
of them by what a paper does or does not already describe. A novel upgrade path and a well-trodden
one are worth exactly the same here, and the well-trodden one is usually worth more. The weaker
"informational link" option is the same cost — a network dependency, a rate limit, a failure mode —
bought for output nobody acts on.

## Consequences

The kit reads the codebase, the toolchain and its own gates, and never the literature; an assessment
never blocks or slows on an external research API.

The one condition that reopens this: the kit starts optimising an **open metric** where "has this
been tried" is genuinely decision-relevant — the same condition that governs ADR-0008, because it
is the same missing premise. Reopening is a fresh ADR plus `set_status deprecated` here, never an
edit in place.

## Prior requests

- `reviews/2026-07-23-jobs/` — "Recherche de nouveauté (novelty search alphaXiv)": an academic
  novelty verdict or prior-art check, read from alphaXiv papers and the arXiv research literature,
  used to rank candidate approaches — "has anyone solved this already" as a gate (2026-07-23).
