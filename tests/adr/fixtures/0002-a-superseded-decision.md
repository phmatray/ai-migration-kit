---
id: 2
title: A superseded decision
status: superseded
date: 2026-08-31
tags:
  - example
links:
  - type: superseded-by
    target: 3
code_refs:
  - path: path/that/exists.md
    symbol: Example
---

# A superseded decision

## Context and Problem Statement

Rule 6's happy path: a `superseded` ADR that DOES carry its `superseded-by` link.
Without this file the rule could only ever be seen failing.

## Considered Options

* Supersede it.
* Deprecate it instead.

## Decision Outcome

Superseded by ADR-0003.

## Consequences

The `superseded-by` link is what keeps the trail walkable.
