---
id: 2
title: The roseline gate fails open, always
status: accepted
date: 2026-08-31
tags:
- hooks
- roseline
code_refs:
- path: hooks/roseline-gate.sh
---

# The roseline gate fails open, always

## Context and Problem Statement

`requirements.json` makes RoselineMCP `level: required`, but preflight can only prove the server is
*connected*; `hooks/roseline-gate.sh` is the PreToolUse hook that proves it is *used*, by denying a
`Read` of a C# file and naming the roseline tool that replaces it. The plugin installs globally, so
that hook runs in every repository the user opens, including ones the kit was never meant to touch.
(Context lifted from the header comment of `hooks/roseline-gate.sh`; #112 and #155 re-derived it.)

## Considered Options

- Fail closed: any uncertainty (no `jq`, an unreadable payload, no launcher on PATH) denies the Read.
- Fail open: any uncertainty exits 0 with no output and lets the Read through.
- Fail closed with a repo allow-list.

## Decision Outcome

Every failure path exits 0 with no output and lets the `Read` through — a missing `jq`, a payload the
hook cannot parse, a path it cannot classify, and "cannot enforce" because roseline's shipped `dnx`
launcher is not on PATH are all the same answer; the gate blocks only where it has positive evidence
that enforcement is meaningful, with `ROSELINE_GATE=off` disabling it outright and `ROSELINE_GATE=on`
overriding the launcher probe (never the off-switch).

## Consequences

A host that has roseline running by some route the probe cannot see (a hand-added server, a locally
built binary) is not enforced unless the user says `ROSELINE_GATE=on` — the price of never
deadlocking an unrelated repository. Because "fails open" is invisible when it fires, it has been
re-derived from scratch twice; that is what this record exists to stop.
