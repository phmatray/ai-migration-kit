---
id: 1
title: An example decision
status: accepted
date: 2026-08-31
tags:
  - example
code_refs:
  - path: path/that/exists.md
---

# An example decision

## Context and Problem Statement

The suite needs one ADR that is valid in every respect, so that each mutation below it
can be attributed to the one thing the case changed.

## Considered Options

* Keep it boring.
* Make it interesting, and lose the attribution.

## Decision Outcome

Keep this file boring on purpose. It carries no `links:` key at all — the server's YAML
serializer omits empty collections, so "no links" is an ABSENT key and never `links: []`.

## Consequences

Every failing case below differs from this file in exactly one way.
