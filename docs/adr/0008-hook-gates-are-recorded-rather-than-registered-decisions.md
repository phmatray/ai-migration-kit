---
id: 8
title: Hook gates are recorded rather than registered decisions
status: accepted
date: 2026-08-31
tags:
- hooks
- decisions
links:
- type: relates-to
  target: 2
code_refs:
- path: decisions/registry.json
- path: hooks/roseline-gate.sh
- path: hooks/git-write-gate.sh
- path: scripts/decision-check.py
---

# Hook gates are recorded rather than registered decisions

## Context and Problem Statement

`decisions/registry.json` gives every control-flow decision one id, one program and one home, and
`scripts/decision-check.py`'s R10 (#252) refuses any tracked script that is neither a registered
decision's `program.path` nor a key of `not_decisions`. Widening R10's enumeration to `hooks/`
(#307) forced the question the narrow globs had let the kit avoid: a PreToolUse hook *looks* exactly
like a decision. `hooks/roseline-gate.sh` branches on `ROSELINE_GATE=off|on`, then on a launcher
probe, then on the file's own extension and project context, and emits allow or deny — #307's own
Problem section calls it "precisely the shape `decisions/registry.json` exists to govern" and its
Alternatives section rejects recording it as "a false claim in the registry".

Two facts pull the other way, and both were discovered only by reading the hook end to end. A
registry row is a claim about a *verdict*: `verdict.source` names how `scripts/decide.sh` extracts
one, and a hook has none to extract — its deny is a `permissionDecision` on stdout in Claude Code's
PreToolUse envelope, consumed by the harness, never by the dispatcher. And R7 requires an *owner*
document that invokes the decision inside a fenced block; a hook is invoked by `hooks/hooks.json`
matching a tool name, so there is no owner to name and nothing for R7 to check.

## Considered Options

- Register each hook, inventing a `verdict.source` for the PreToolUse envelope and relaxing R7 for
  decisions with no owner document.
- Record each hook in `not_decisions`, with a reason that says which of the two tests it fails.
- Leave `hooks/` outside R10's enumeration, as before #307.

## Decision Outcome

Hooks are **recorded** in `not_decisions`, not registered: a registry row is a claim that
`decide.sh` dispatches this program and that an owner document invokes it, and a hook satisfies
neither — so a row would have to be paid for by weakening R7 and by adding a verdict source no
dispatcher implements, buying a claim about a program CI would still never run. #353 already
recorded `hooks/git-write-gate.sh` this way; #307 records `hooks/roseline-gate.sh` on the same
terms, and R10 now enumerates `hooks/` so a *third* hook must be classified rather than ignored.

## Consequences

The registry's own guarantee gets narrower and more honest: it governs the decisions `decide.sh`
runs, not every allow/deny in the kit. What keeps that from being a hiding place is R10 — since
#307 no hook can be silently absent, and each one's `not_decisions` reason has to name why it is not
a decision, so the classification is a per-file claim a reviewer can dispute rather than an
omission nobody sees.

The counter-argument is real and is the reason this record exists: a fail-open access-control gate
is exactly the kind of file the `decisions/` system was built to catch, and "recorded as not a
decision" reads like the drift the system prevents. It is not the same thing — a recorded file is
enumerated, named and reasoned about — but the resemblance is close enough that #307 argued the
opposite position in writing before the hooks were read. Reverse this only by giving `decide.sh` a
PreToolUse verdict source and R7 an answer for an ownerless decision; both hooks then move together,
because ADR 0002 already establishes they take the same terms.
