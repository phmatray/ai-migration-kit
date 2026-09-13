---
id: 15
title: The lifecycle skills reach the tracker through one contract
status: accepted
date: 2026-09-13
tags:
- lifecycle
- tracker
code_refs:
- path: scripts/tracker.sh
- path: scripts/tracker/contract.json
- path: scripts/tracker/capable.sh
- path: skills/_shared/tracker-contract.md
parent: Architectural Decision Records
nav_order: 15
---

# The lifecycle skills reach the tracker through one contract

## Context and Problem Statement

Every tracker operation in this kit was a direct `gh` call — 111 lines across 18 scripts and 189
across 39 prose files — and `skills/_shared/preconditions.md` could answer only "GitHub, or stop".
#503 asked for GitLab and Azure DevOps support, and there was nowhere to put it: no place a second
host's dialect could live, and no way to state a partial answer such as "`create-issue` works on
GitLab, `merge-pr` does not yet". The refusal a non-GitHub repository met was also generic — it named
the tracker but not which skill was blocked or what would unblock it.

## Considered Options

- **Keep `gh` everywhere and refuse anything else at preconditions.** The status quo: cheapest, and
  it keeps GitHub byte-identical, but #503 is unimplementable under it and the refusal stays generic.
- **An adapter per skill** — each skill learns the hosts it supports, calling each host's CLI
  directly. No new indirection on the GitHub path, but the host dialect spreads across 18 scripts
  again, once per skill, and "which hosts work?" has as many answers as there are skills.
- **One contract with a per-host backend and a registered capability verdict.** A verb has one name
  and one normalised stdout; a backend implements verbs for one host; a registered decision answers
  whether a given skill may run against a given host.

## Decision Outcome

The kit takes the third option: `scripts/tracker.sh` routes a named verb to
`scripts/tracker/<tracker>.sh`, the verb table lives once in `scripts/tracker/contract.json`, and the
registered decision `tracker.capable` — asked at Step 1 of every lifecycle skill — answers `capable`,
`missing` or `unsupported` from the `state` report the dispatcher produces. GitHub is the **reference**
backend and is deliberately never reduced to a lowest common denominator: a verb prints what GitHub
can actually say, and a host that cannot say it answers `NOT_IMPLEMENTED` rather than every host
answering less. Because GitHub answers `capable` for every skill — an unmigrated skill's direct `gh`
calls are correct there — this change refuses nothing that worked before it, and a relation a host
simply lacks (a sub-issue edge, a blocked-by link) degrades through the established `fallback` rule
rather than failing the verb.

## Consequences

The GitHub path gains one indirection for each migrated call site, which buys a single home for the
host dialect and a refusal that can finally name both the skill and the remedy. A skill stays locked
to a host until every verb it needs exists there — `missing` until somebody lists it on the contract —
which is the honest answer rather than a gap, since nothing has yet established which verbs it needs.
The migration is deliberately incremental: this record covers the *expand* step only, no call site
moves with it, and `contract.json`'s `skills` map is empty until the first skill migrates. This is
consistent with ADR-0014 on a different axis: 0014 is about which **host** program loads the kit, this
is about which **tracker** a repository files against, and the two vary independently — Claude Code
against GitLab is as coherent a combination as Codex against GitHub. Reopens when: a second backend
lands and the verb table proves to need a shape `contract.json` cannot express, or when a host's
relation model makes the `fallback` rule insufficient.
