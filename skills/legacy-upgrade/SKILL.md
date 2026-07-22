---
name: legacy-upgrade
description: Use when upgrading, migrating, or modernizing a legacy application — outdated target framework, out-of-support runtime, obsolete APIs, old packages, or legacy idioms. Triggers on "upgrade this app", "migrate to .NET 10", "modernize this codebase", "this project targets an old framework", /migrate, /migrate-assess, /migrate-verify. Drives a six-phase, gate-verified pipeline where RoselineMCP performs all C# analysis and code transformation.
---

# Legacy Upgrade Pipeline

Upgrade a legacy application completely, verifiably, easily, and fast. You are the orchestrator: drive the six phases **in order**, never advancing past a red gate.

## Hard rules

1. **RoselineMCP is mandatory for C#.** Every C# analysis (diagnostics, references, call graphs, symbol lookup) and every C# code mutation (bulk fixes, member edits, renames) goes through RoselineMCP tools — see `references/roseline-playbook.md`. Use plain Read/Grep/Edit only for non-C# files (csproj, config, docs).
2. **Preview first.** Every RoselineMCP mutation (`apply_fixes`, `edit_member`, `rename_symbol`) runs in preview mode first; inspect the diff, then re-run with `previewOnly: false`.
3. **Red gate stops the pipeline.** If a gate fails (build, tests, diagnostics regression), fix it or roll back the phase. Never continue past a failing gate, never weaken a gate to pass it.
4. **Branch and commit discipline.** Work on a dedicated `migration/<yyyy-mm-dd>` branch in the target repo. Commit at every green gate with a message naming the phase.
5. **No behavior changes.** The migration preserves observable behavior. Behavior fixes discovered along the way are recorded in the report as follow-ups, not applied.

## The pipeline

| # | Phase | Purpose | Exit gate | Reference |
|---|-------|---------|-----------|-----------|
| 1 | Assess | Read-only inventory and risk map | `migration/assessment.md` written; zero files modified | `references/phase-1-assess.md` |
| 2 | Baseline | Prove the app is green before touching it | Build + tests green; `migration/baseline.md` committed | `references/phase-2-baseline.md` |
| 3 | Retarget | New TFM + updated packages, dependency order | Full solution builds on the new TFM | `references/phase-3-retarget.md` |
| 4 | Remediate | Drive diagnostics to zero errors | 0 errors, warnings ≤ baseline, tests green | `references/phase-4-remediate.md` |
| 5 | Modernize | Opt-in idiom upgrades | Build + tests green after each item | `references/phase-5-modernize.md` |
| 6 | Verify | Final gate + report | `migration/report.md` written; all gates green | `references/phase-6-verify.md` |

Load each phase's reference file **when you enter that phase**, not before — keep context small.

## Artifact contract

All pipeline artifacts live in a `migration/` folder at the target repo root:

- `migration/assessment.md` — phase 1 output (inventory, diagnostics histogram, risk map, recommended target).
- `migration/baseline.md` — phase 2 output (build/test/diagnostic counts that later gates compare against).
- `migration/report.md` — phase 6 output (before/after evidence, changes, follow-ups).

## Scope variants

- `/migrate` — phases 1–6.
- `/migrate-assess` — phase 1 only. Absolute guarantee: no file in the target repo is created or modified except `migration/assessment.md`.
- `/migrate-verify` — phase 6 only; re-runnable at any time after a migration.
- Non-.NET legacy apps: the six-phase methodology still applies, but phases 3–5 use the ecosystem's own tooling; RoselineMCP covers the C# path.
