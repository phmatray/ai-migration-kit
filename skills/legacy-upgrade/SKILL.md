---
name: legacy-upgrade
description: >-
  Use when upgrading, migrating, or modernizing a legacy application — outdated target framework,
  out-of-support runtime, obsolete APIs, old packages, or legacy idioms. Triggers on "upgrade this
  app", "migrate to .NET 10", "modernize this codebase", "this project targets an old framework",
  « mets à niveau cette app », « migre vers .NET 10 », « modernise ce code legacy », /migrate,
  /migrate-assess, /migrate-verify. Drives a six-phase, gate-verified pipeline where RoselineMCP
  performs all C# analysis and code transformation.
license: MIT
compatibility: >-
  Requires the RoselineMCP server (Roslyn) for all C# analysis and mutation, a .NET SDK >= 8, git
  and python3. Recommended: context7 MCP, gh CLI, node, headless Chrome. Canonical manifest:
  requirements.json at the kit root, verified by scripts/preflight.sh (phase 0).
metadata:
  author: Philippe Matray
  version: 1.6.0
  suite: ai-migration-kit
---

# Legacy Upgrade Pipeline

Upgrade a legacy application completely, verifiably, easily, and fast. You are the orchestrator: drive the phases **in order**, never advancing past a red gate.

## Phase 0 — Préflight (avant toute autre action)

1. **Exécuter `scripts/preflight.sh`** (déterministe ; un REQUIS manquant = stop). La liste canonique des prérequis — outils, serveurs MCP, skills de session, avec leur niveau requis/recommandé — vit dans **`requirements.json`** à la racine du kit : le script la lit, rien n'est dupliqué ici. Pour ajouter ou retirer un prérequis, on édite CE fichier. Relancer avec `--json` pour la version machine à verser dans `migration/report.json`.
2. **Confirmer les capacités de session** (le script ne voit pas la session) : pour chaque entrée `sessionSkills` et chaque MCP de `requirements.json`, vérifier la présence dans TA liste de skills/outils. Les moments d'usage restent des règles dures : `mcp__roseline__*` **obligatoire** pour tout C# (sinon stop et demander la configuration) ; `context7` avant les phases 3/5 et avant toute UI ; `frontend-design` **avant d'écrire une UI réécrite** ; `dataviz` + `artifact-design` **avant tout dashboard** (audit ou rapport).
3. **Dégradation documentée, jamais silencieuse** : chaque capacité recommandée absente est consignée dans le rapport avec la parade utilisée (sortie `preflight.sh --json` + les confirmations de session ; règle identique au repli RoselineMCP de l'audit).

## Hard rules

1. **RoselineMCP is mandatory for C#.** Every C# analysis (diagnostics, references, call graphs, symbol lookup) and every C# code mutation (bulk fixes, member edits, renames) goes through RoselineMCP tools — see `references/roseline-playbook.md`. Use plain Read/Grep/Edit only for non-C# files (csproj, config, docs).
2. **Preview first.** Every RoselineMCP mutation (`apply_fixes`, `edit_member`, `rename_symbol`) runs in preview mode first; inspect the diff, then re-run with `previewOnly: false`.
3. **Red gate stops the pipeline.** If a gate fails (build, tests, diagnostics regression), fix it or roll back the phase. Never continue past a failing gate, never weaken a gate to pass it.
4. **Branch and commit discipline.** Work on a dedicated `migration/<yyyy-mm-dd>` branch in the target repo. Commit at every green gate with a message naming the phase.
5. **No behavior changes.** The migration preserves observable behavior. Behavior fixes discovered along the way are recorded in the report as follow-ups, not applied.
6. **The deliverable never narrates its migration.** No banner, footer, meta tag or user-facing string mentions the port, the tooling or the process — the end user gets a product, not a case study. Provenance lives in the README, `migration/report.md` and git history. (In-code comments that encode a maintenance constraint — "verbatim port, do not modernize" — stay.)
7. **Scripts et templates du kit obligatoires.** Quand le kit fournit un outil pour une étape, l'improvisation est interdite : inventaire → `scripts/audit-inventory.sh` ; rapport → `scripts/report-dashboard.py` (jamais de HTML manuel) ; CI → `templates/ci-dotnet.yml` ; déploiement Blazor → `templates/deploy-pages-blazor.yml`. C'est ce qui rend les migrations reproductibles et comparables.
8. **Livrée = en production.** Le pipeline ne s'arrête pas au vert local : suivre `references/delivery-playbook.md` (branche par défaut, workflows depuis les templates, Pages, vérification de la prod avec route profonde + capture regardée). La phase 7 se conclut par un passage du skill `followups` (`scripts/followups.py` sur les repos migrés) : la queue de suivis — décisions propriétaire, tâches, différés — est présentée à jour au moment de quitter le repo. Un suivi qui mérite un ticket se convertit en issue GitHub via le skill `create-issue` du kit (voir le skill `followups`).

## The pipeline

| # | Phase | Purpose | Exit gate | Reference |
|---|-------|---------|-----------|-----------|
| 1 | Assess | Read-only inventory and risk map | `migration/assessment.md` written; zero files modified | `references/phase-1-assess.md` |
| 2 | Baseline | Prove the app is green before touching it | Build + tests green; `migration/baseline.md` committed | `references/phase-2-baseline.md` |
| 3 | Retarget | New TFM + updated packages, dependency order | Full solution builds on the new TFM | `references/phase-3-retarget.md` |
| 4 | Remediate | Drive diagnostics to zero errors | 0 errors, warnings ≤ baseline, tests green | `references/phase-4-remediate.md` |
| 5 | Modernize | Opt-in idiom upgrades | Build + tests green after each item | `references/phase-5-modernize.md` |
| 6 | Verify | Final gate + report | `migration/report.html` généré + `report.md`; all gates green | `references/phase-6-verify.md` |
| 7 | Deliver | Production (CI, Pages, vérif) | URL publique vérifiée (route profonde + capture) | `references/delivery-playbook.md` |

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

## Common issues (error → cause → solution)

| Error | Cause | Solution |
|---|---|---|
| Preflight prints `PRÉFLIGHT ÉCHOUÉ` on a required line | Required tool absent (dotnet/git/python3) or RoselineMCP not connected | Install the tool / `claude mcp add roseline …`, re-run `scripts/preflight.sh` — never start phase 1 on red |
| `mcp__roseline__*` missing from the session's tool list | Server configured but this session started without it (or it died) | Check `claude mcp list`, restart the session; without roseline, stop — hard rule 1 forbids C# work without it |
| Build red right after the phase 3 retarget | Packages bumped out of dependency order | Roll back to the last green-gate commit; re-bump following the dependency graph, building between bumps |
| Phase 4 gate: warnings above baseline | Bulk fixes introduced new diagnostics | `list_diagnostics` grouped by id, fix by code — never widen the baseline to pass the gate |
| `dotnet test` fails locally on a missing prerequisite (workload, DB) | The app has a CI-only prerequisite | Run per-project builds / filtered suites and record the degradation in the report — documented, never silent |
