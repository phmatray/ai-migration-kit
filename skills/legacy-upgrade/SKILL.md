---
name: legacy-upgrade
description: >-
  Use when upgrading, migrating, or modernizing a legacy application — outdated target framework,
  out-of-support runtime, obsolete APIs, old packages, or legacy idioms. Triggers on "upgrade this
  app", "migrate to .NET 10", "modernize this codebase", "this project targets an old framework",
  « mets à niveau cette app », « migre vers .NET 10 », « modernise ce code legacy », /migrate,
  /migrate-assess, /migrate-verify. Drives a seven-phase, gate-verified pipeline — assessment
  through verified production — where RoselineMCP performs all C# analysis and code transformation.
license: MIT
compatibility: >-
  Requires the RoselineMCP server (Roslyn) for all C# analysis and mutation, a .NET SDK >= 8, git
  and python3. Recommended: context7 MCP, gh CLI, node, headless Chrome. Canonical manifest:
  requirements.json at the kit root, verified by scripts/preflight.sh (phase 0).
metadata:
  author: Philippe Matray
  version: 1.7.0
  suite: ai-migration-kit
---

# Legacy Upgrade Pipeline

Upgrade a legacy application completely, verifiably, easily, and fast. You are the orchestrator: drive the phases **in order**, never advancing past a red gate.

Throughout this skill and its references, **`<kit>`** is the plugin root — resolve it as
`<skill-dir>/../..`, where `<skill-dir>` is this skill's base directory (given when the skill
loads). Every kit script and template path (`<kit>/scripts/…`, `<kit>/templates/…`) resolves from
there — never from the current working directory, which is the *target* repo.

## Phase 0 — Preflight (before anything else)

1. **Run `<kit>/scripts/preflight.sh`** (deterministic; a missing REQUIRED item = stop). The canonical prerequisite list — tools, MCP servers, session skills, each required or recommended, plus the `requiredBy` list where a specific skill hard-requires an entry — lives in **`<kit>/requirements.json`**: the script reads it, nothing is duplicated here. To add or remove a prerequisite, edit THAT file. Re-run with `--json` for the machine version to store in `migration/report.json`.
2. **Confirm the session capabilities** (the script cannot see the session): for every `sessionSkills` entry and every MCP in `requirements.json`, verify presence in YOUR list of skills/tools. The usage moments stay hard rules: `mcp__roseline__*` **mandatory** for any C# (otherwise stop and ask for the configuration); `context7` before phases 3/5 and before any UI; `frontend-design` **before writing a rewritten UI**; `dataviz` + `artifact-design` **before any dashboard** (audit or report).
3. **Documented degradation, never silent**: every absent recommended capability is recorded in the report with the fallback used (`preflight.sh --json` output + the session confirmations; same rule as the audit's RoselineMCP fallback).

## Hard rules

1. **RoselineMCP is mandatory for C#.** Every C# analysis (diagnostics, references, call graphs, symbol lookup) and every C# code mutation (bulk fixes, member edits, renames) goes through RoselineMCP tools — see `references/roseline-playbook.md`. Use plain Read/Grep/Edit only for non-C# files (csproj, config, docs).
2. **Preview first.** Every RoselineMCP mutation (`apply_fixes`, `edit_member`, `rename_symbol`) runs in preview mode first; inspect the diff, then re-run with `previewOnly: false`.
3. **Red gate stops the pipeline.** If a gate fails (build, tests, diagnostics regression), fix it or roll back the phase. Never continue past a failing gate, never weaken a gate to pass it.
4. **Branch and commit discipline.** Work on a dedicated `migration/<yyyy-mm-dd>` branch in the target repo. Commit at every green gate with a message naming the phase.
5. **No behavior changes.** The migration preserves observable behavior. Behavior fixes discovered along the way are recorded in the report as follow-ups, not applied.
6. **The deliverable never narrates its migration.** No banner, footer, meta tag or user-facing string mentions the port, the tooling or the process — the end user gets a product, not a case study. Provenance lives in the README, `migration/report.md` and git history. (In-code comments that encode a maintenance constraint — "verbatim port, do not modernize" — stay.)
7. **Kit scripts and templates are mandatory.** When the kit ships a tool for a step, improvising is forbidden: inventory → `<kit>/scripts/audit-inventory.sh`; report → `<kit>/scripts/report-dashboard.py` (never hand-written HTML); CI → `<kit>/templates/ci-dotnet.yml`; Blazor deployment → `<kit>/templates/deploy-pages-blazor.yml`. This is what makes migrations reproducible and comparable.
8. **Delivered = in production.** The pipeline does not stop at local green: follow `references/delivery-playbook.md` (default branch, workflows from the kit templates, Pages, production verified with a deep route + a reviewed screenshot). Phase 7 closes with a pass of the `followups` skill (`<kit>/scripts/followups.py` over the migrated repos): the follow-up queue — owner decisions, tasks, deliberate deferrals — is presented up to date before leaving the repo. A follow-up that deserves a real ticket becomes a GitHub issue via the kit's `create-issue` skill (see the `followups` skill). An app with **no production target** closes phase 7 by recording that owner decision in the report — documented, never silent.

## The pipeline

| # | Phase | Purpose | Exit gate | Reference |
|---|-------|---------|-----------|-----------|
| 1 | Assess | Read-only inventory and risk map | `migration/assessment.md` written; zero files modified | `references/phase-1-assess.md` |
| 2 | Baseline | Prove the app is green before touching it | Build + tests green; `migration/baseline.md` committed | `references/phase-2-baseline.md` |
| 3 | Retarget | New TFM + updated packages, dependency order | Full solution builds on the new TFM | `references/phase-3-retarget.md` |
| 4 | Remediate | Drive diagnostics to zero errors | 0 errors, warnings ≤ baseline, tests green | `references/phase-4-remediate.md` |
| 5 | Modernize | Opt-in idiom upgrades | Build + tests green after each item | `references/phase-5-modernize.md` |
| 6 | Verify | Final gate + report | `migration/report.html` generated + `report.md`; all gates green | `references/phase-6-verify.md` |
| 7 | Deliver | Production (CI, Pages, verification) | Public URL verified (deep route + reviewed screenshot) | `references/delivery-playbook.md` |

Load each phase's reference file **when you enter that phase**, not before — keep context small.

## Artifact contract

All pipeline artifacts live in a `migration/` folder at the target repo root:

- `migration/assessment.md` — phase 1 output (inventory, diagnostics histogram, risk map, recommended target).
- `migration/baseline.md` — phase 2 output (build/test/diagnostic counts that later gates compare against).
- `migration/report.md` — phase 6 output (before/after evidence, changes, follow-ups).

## Scope variants

- `/migrate` — the full pipeline, phases 1–7 (assess → deliver). It ends in verified production (hard rule 8) — or with the recorded owner decision when no production target exists.
- `/migrate-assess` — phase 1 only. Absolute guarantee: no file in the target repo is created or modified except `migration/assessment.md`.
- `/migrate-verify` — phase 6 only; re-runnable at any time after a migration.
- Non-.NET legacy apps: the same seven-phase methodology applies, but phases 3–5 use the ecosystem's own tooling; RoselineMCP covers the C# path.

## Common issues (error → cause → solution)

| Error | Cause | Solution |
|---|---|---|
| Preflight prints `PREFLIGHT FAILED` on a required line | Required tool absent (dotnet/git/python3) or RoselineMCP not connected | Install the tool / `claude mcp add roseline …`, re-run `<kit>/scripts/preflight.sh` — never start phase 1 on red |
| `mcp__roseline__*` missing from the session's tool list | Server configured but this session started without it (or it died) | Check `claude mcp list`, restart the session; without roseline, stop — hard rule 1 forbids C# work without it |
| Build red right after the phase 3 retarget | Packages bumped out of dependency order | Roll back to the last green-gate commit; re-bump following the dependency graph, building between bumps |
| Phase 4 gate: warnings above baseline | Bulk fixes introduced new diagnostics | `list_diagnostics` grouped by id, fix by code — never widen the baseline to pass the gate |
| `dotnet test` fails locally on a missing prerequisite (workload, DB) | The app has a CI-only prerequisite | Run per-project builds / filtered suites and record the degradation in the report — documented, never silent |
