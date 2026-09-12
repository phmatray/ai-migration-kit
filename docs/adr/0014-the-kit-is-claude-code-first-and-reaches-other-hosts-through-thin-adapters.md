---
id: 14
title: The kit is Claude Code-first and reaches other hosts through thin adapters
status: accepted
date: 2026-09-11
tags:
- harness
- distribution
links:
- type: supersedes
  target: 6
parent: Architectural Decision Records
nav_order: 14
---

# The kit is Claude Code-first and reaches other hosts through thin adapters

## Context and Problem Statement

ADR 0006 (2026-08-31) made the kit Claude Code only: hooks, the bundled MCP servers, slash commands and inter-skill relative links are used directly, because every abstraction that would make them harness-neutral would also weaken them in the one host actually supported. By September 2026 the layout the kit already ships — `skills/*/SKILL.md`, a plugin `.mcp.json`, a hooks map, `commands/*.md` — is what Codex, GitHub Copilot CLI, Gemini CLI, Antigravity CLI and pi load natively through a manifest of their own, and a dozen editors and agents (Cursor, Windsurf, Cline, Kiro, GitHub Copilot, Zed, Amp, Jules, Junie, OpenCode) load an `AGENTS.md` or a rules file. ponytail (dietrichgebert/ponytail) reaches about twenty hosts that way, with thin adapter files over one skills tree. The owner asked for the same reach (#524). ADR 0006's objection was to a portability layer inside the skills; what these hosts ask for is a manifest pointing at files the kit already has.

## Considered Options

- Keep targeting Claude Code only (ADR 0006) — the kit stays out of reach of every other host, however little they would need from it.
- A portability layer inside the skills — probe for hooks, sub-agents and MCP servers at run time so every skill behaves the same everywhere. Declined again, for 0006's own reason: it would weaken the kit in Claude Code and rewrite thirteen skills.
- Packages and installers per host — ponytail's npm package, a JavaScript OpenCode plugin, a kit MCP server. Declined: a build and publish pipeline in a repository that ships as files, with release secrets and a JavaScript runtime to carry.
- Thin adapters over the unchanged skills — one manifest or generated rule copy per host, checked for drift in CI. Chosen.

## Decision Outcome

The skills stay Claude Code-first — no portability layer, and no per-host branch in any `SKILL.md` — and every other host reaches them through a thin adapter that points at the files the kit already has: a plugin manifest (`.codex-plugin/plugin.json`, `.github/plugin/plugin.json`, `gemini-extension.json` for Gemini CLI and Antigravity CLI, `package.json` for pi) or a rule copy generated from `AGENTS.md` (Cursor, Windsurf, Cline, Kiro, GitHub Copilot, Antigravity). `AGENTS.md` is the one home of the routing table. `scripts/host-adapters.py` generates everything derived and refuses drift; `docs/_data/hosts.yml` is the one table of hosts and what each gets. Claude Code's hook map moves to `hooks/claude-hooks.json`, off the path Gemini CLI and Copilot CLI auto-load in formats of their own. What a host cannot run — Claude Code's hook payloads, Agent-tool sub-agents — degrades there, fails open (ADR 0002), and is named per host on the Platforms page rather than abstracted away.

## Consequences

Good: the kit installs as a plugin on six hosts and loads through a rule file on a dozen more, and nothing in a skill changed shape to get there. Bad: every host is one more file to keep current. `host-adapters.py check` keeps versions, component paths and generated files in step on every CI run, but a host changing its own manifest format is still ours to notice. Hosts without Claude Code's hooks run without the gates, and hosts without sub-agents cannot run `auto-dev` or `deliver-issue`. A host is added by adding a row to `docs/_data/hosts.yml` and its adapter — never by editing a skill.
