---
id: 6
title: The kit targets Claude Code only
status: accepted
date: 2026-08-31
tags:
- harness
- distribution
code_refs:
- path: hooks/hooks.json
- path: .mcp.json
- path: commands/auto-dev-worker.md
---

# The kit targets Claude Code only

## Context and Problem Statement

The kit is built out of mechanisms only one harness provides: a `PreToolUse` hook manifest, a plugin
`.mcp.json` that ships its own MCP servers, slash commands under `commands/`, and skills that resolve
each other through `_shared/` relative links. Portability to other agent harnesses was evaluated in
the v2 meta review and declined. (This decision previously lived nowhere — it was implied by the
directory layout, which is why it is recorded here.)

## Considered Options

- Target Claude Code only, and use its mechanisms without abstraction.
- Abstract the harness behind an adapter so the skills could run elsewhere.
- Ship the skills as harness-neutral prose and leave the wiring to the consumer.

## Decision Outcome

The kit targets Claude Code and only Claude Code: hooks, the bundled MCP servers, slash commands and
inter-skill relative links are used directly, with no portability layer, because every abstraction
that would make them harness-neutral would also make them weaker in the one harness that is actually
supported.

## Consequences

Another harness cannot run the kit without reimplementing its wiring, and a Claude Code mechanism
that changes shape is a breaking change for the whole kit rather than for one adapter. In exchange
the skills can rely on hooks, sub-agents and MCP servers being present rather than probing for them.
