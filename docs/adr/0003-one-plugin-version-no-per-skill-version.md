---
id: 3
title: One plugin version; no per-skill version
status: accepted
date: 2026-08-31
tags:
- release
- skills
code_refs:
- path: tests/skills/check-frontmatter.py
- path: .claude-plugin/plugin.json
---

# One plugin version; no per-skill version

## Context and Problem Statement

Skill frontmatter can carry arbitrary metadata, and a `version` key looks like ordinary hygiene, so
several skills grew one. The plugin ships as a single unit: there is no way to install
`migrate-legacy` at one version alongside `merge-pr` at another. (Context lifted from
`ARCHITECTURE.md` §Versioning and the docstring of `tests/skills/check-frontmatter.py`; #16.)

## Considered Options

- A `version` key per skill, bumped by whoever edits the skill.
- One version, in `.claude-plugin/plugin.json`, and no per-skill version at all.

## Decision Outcome

There is exactly one version — `.claude-plugin/plugin.json`, bumped by release-please — and a
`version` key in skill frontmatter is **rejected** by `tests/skills/check-frontmatter.py`, at top
level and under `metadata`, in every YAML spelling; a per-skill version would advertise a granularity
that does not exist, and nothing would bump it (six had already drifted behind `plugin.json` before
the field was removed).

## Consequences

The check parses the frontmatter rather than pattern-matching it, because pattern-matching got this
wrong in both directions — it missed the quoted spellings and fired on prose inside a `>-` block —
so `tests/skills/test.sh` drives it against fixtures for both.
