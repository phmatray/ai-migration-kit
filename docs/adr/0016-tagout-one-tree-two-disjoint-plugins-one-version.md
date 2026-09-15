---
id: 16
title: 'Tagout: one tree, two disjoint plugins, one version'
status: accepted
date: 2026-09-14
tags:
- distribution
- release
code_refs:
- path: .claude-plugin/marketplace.json
- path: scripts/host-adapters.py
parent: Architectural Decision Records
nav_order: 16
---

# Tagout: one tree, two disjoint plugins, one version

## Context and Problem Statement

The kit was named `ai-migration-kit` for the half most consumers never install. Its issue → pull request lifecycle (`create-issue`, `implement-issue`, `merge-pr`, `auto-dev`, `triage-backlog`) runs on any repository every day; the seven-phase .NET pipeline runs once, on a legacy application. Measured on 2026-09-14: 3 stars, 1 fork, 19 unique visitors in fourteen days — nothing to protect, and every new install cements a name that costs more to change later. The name is an identifier six times over (ADR 0012): the repository and its Pages URL, two marketplace files, six host manifests, the `suite:` line of twelve skill frontmatters, the state paths two scripts write under, and 100 tracked files once history is excluded.

The shape was wrong too. #607 measured, with `claude plugin marketplace add <path>`, `install` and `details` on scratch copies of this tree, that a lifecycle-only team loads 17 components, a `Read` hook and two `dnx` servers where 12 components and no .NET would do — and that a plugin cannot be narrowed from a manifest: a marketplace entry's component lists are ignored when the source carries a `plugin.json`, a `skills/` directory at a plugin root is always discovered in full, a symlinked skill *directory* is discovered but a symlinked command *file* is not, and installed plugins are dereferenced into a cache.

A naming study (46 candidates over GitHub, npm, PyPI, crates.io, the web and domains) found the whole gate/threshold word field already taken by AI-agent tools — gatekit, sprag, detent, limen, gatelane, greenlight, redgreen — so a descriptive name is not ownable. **Tagout** is the docs site's own creative north star (`DESIGN.md`: a gate that refuses by name is a lock-out / tag-out tag hung on the machine — who locked it, why, what clears it), free on npm and crates.io, two stars at most on GitHub. The owner validated it on 2026-09-14 (#610).

## Considered Options

- Rename only, keep one plugin — the cheapest change, but the name would say "lifecycle" while every session still loads the .NET pipeline, its hook and its servers.
- Rename, and ship two disjoint plugins from one tree — `plugins/tagout/` and `plugins/tagout-migrate/`, each a manifest plus per-skill directory symlinks and generated copies of its commands, hooks map and `.mcp.json`; no file under `skills/` moves; the root is no longer a Claude Code plugin. Chosen.
- Move the migration half out of `skills/` into a plugin directory as real files — no symlinks, but every gate that globs `skills/` learns a second root and every `<kit>/skills/migrate-legacy` path breaks; a second major for the same result.
- Two repositories — forks `skills/_shared/`, `tests/_lib.sh`, release-please, `host-adapters.py` and the docs site, against the one-home doctrine (#324).

## Decision Outcome

The kit is **Tagout** — repository `phmatray/tagout`, marketplace `tagout-marketplace`, `suite: tagout` — and it ships as two disjoint Claude Code plugins from one tree at one version (ADR 0003): `tagout` (`plugins/tagout/`) is the lifecycle — ten skills, two commands, three hooks, no MCP server, no .NET prerequisite — and `tagout-migrate` (`plugins/tagout-migrate/`) is the .NET pipeline — `migrate-legacy`, `review-followups`, five commands, the roseline `Read` gate, `roseline` + `adr` — installed beside it. Each plugin directory holds a hand-written manifest, per-skill and per-directory symlinks into the one `skills/`, `scripts/`, `hooks/` and their siblings, and copies of its commands, hooks map and `.mcp.json` that `scripts/host-adapters.py build` writes and `check` refuses to see edited; `check` also keeps the partition complete — every skill linked from exactly one plugin, every link pointing at its namesake, no `.mcp.json` under `plugins/tagout/`, every `<kit>/<path>` a plugin's skills name resolving inside it. The other hosts' root manifests (Codex, Copilot, Gemini, pi) keep shipping the whole kit under the new name. The change ships as one major (`feat!`, ADR 0012's window), in three PRs: the identifiers (#611), the two plugin directories (#607), the rebrand (#612).

## Consequences

Good: a consumer installs the loop they run every day under a name that says so, with nothing they do not run loaded into their sessions; the .NET pipeline becomes an add-on found by its topics rather than the identity of the whole repository; nothing under `skills/`, `commands/`, `hooks/` or `scripts/` moved, so every `<kit>/…` path and every gate that globs `skills/` is unchanged. Bad: one reinstall per consumer (`tagout@tagout-marketplace`), and the old marketplace name stops resolving once the release lands; git symlinks are now tracked, and a Windows checkout without `core.symlinks` gets two broken plugin directories while the other hosts' root manifests still work — copy-by-`build` is the remedy if a consumer asks (it stopped being optional on the first Windows install: ADR 0017 makes the plugin directories generated copies, #619); fleet state written under `…/ai-migration-kit/auto-dev/` is orphaned by the state-path move, and a running fleet finishes on the old plugin version; the routing table `hooks/routing-context.sh` injects still names `/migrate` in a lifecycle-only session. History keeps the old name: `CHANGELOG.md`, `docs/journal/`, `reviews/`, `docs/adr/`, `docs/case-studies/`, the dated design records under `docs/superpowers/` and the frozen `samples/` fixture are never rewritten, and the release-please PR is held until all three slices have landed so `3.0.0` is the rename and the split together.
