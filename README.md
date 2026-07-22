# AI Migration Kit

> « Mise à niveau complète, parfaite, facile et rapide de n'importe quelle application legacy » — powered by **RoselineMCP**.

A Claude Code plugin that upgrades legacy .NET applications through a six-phase, gate-verified pipeline. RoselineMCP (a Roslyn-powered MCP server) is the engine for every C# analysis and transformation step: solution diagnostics, bulk code fixes, surgical member edits, safe renames, and impact analysis via references and call graphs.

- **Complete** — from first assessment to a verified migration report, not just a csproj bump.
- **Verified** — every phase ends at a gate (build, tests, diagnostics baseline); a red gate stops the pipeline.
- **Easy** — one command: `/migrate`. Start read-only with `/migrate-assess`.
- **Fast** — mechanical fixes are applied in bulk with Roslyn code fixes; agent time is spent only on judgment calls.

## Prerequisites

- [Claude Code](https://code.claude.com) with the **RoselineMCP** server configured (`claude mcp list` should show `roseline`).
- .NET SDK for the target framework (latest LTS recommended).
- The target application in a git repository.

## Install

```bash
claude plugin marketplace add phmatray/ai-migration-kit   # or the local path to this repo
claude plugin install ai-migration-kit
```

## Quickstart

```text
cd your-legacy-app
claude
> /migrate-assess          # read-only audit → migration/assessment.md
> /migrate                 # full pipeline (phases 1–6)
> /migrate-verify          # re-runnable final quality gate
```

## The audit product — `/migrate-audit`

The kit's front door: a **read-only executive audit** that speaks to decision-makers, not just developers. For each target app it delivers a costed report — technology era, UI surface, platform-API mapping, share of business logic that ports as-is, effort estimate in days (transparent formula, ±30%), recommended target (Blazor WASM/Server/Hybrid), risk register and cost of inaction. Point it at several apps and it adds a **portfolio synthesis**: value/effort matrix, migration order, first wave. Every number comes from `scripts/audit-inventory.sh` (reproducible JSON), and it also covers dead-platform apps (WinRT, UWP, Windows Phone → Blazor) where the question is UI rewrite + logic porting, not a TFM bump. See the real case study: [docs/case-studies/winrt-portfolio/](docs/case-studies/winrt-portfolio/).

## The pipeline

| # | Phase | Purpose | Key RoselineMCP tools | Exit gate |
|---|-------|---------|----------------------|-----------|
| 1 | **Assess** | Read-only inventory: TFMs, packages, diagnostics, risk map | `analyze_solution`, `search_symbols` | `migration/assessment.md` written, zero files touched |
| 2 | **Baseline** | Build + tests green; characterization tests where coverage is missing | `get_call_graph`, `analyze_solution` | Green build + tests, baseline recorded |
| 3 | **Retarget** | Bump TFMs and packages in dependency order | `get_symbol_at_position`, `find_references` | Solution builds on the new TFM |
| 4 | **Remediate** | Drive diagnostics to zero errors; bulk-fix mechanical issues | `list_diagnostics`, `apply_fixes`, `edit_member` | 0 errors, warnings ≤ baseline, tests green |
| 5 | **Modernize** | Opt-in idiom upgrades (nullable, async, file-scoped namespaces) | `find_references`, `rename_symbol`, `edit_member` | Build + tests green after each item |
| 6 | **Verify** | Final gate + generated executive dashboard | `analyze_solution` | `migration/report.html` (generated) + `report.md`, all green |
| 7 | **Deliver** | CI + deployment from kit templates, production verified | — | public URL answers on deep routes, screenshot reviewed |

A **phase 0 preflight** (`scripts/preflight.sh`) gates the whole pipeline: required tooling (dotnet, git, python3, **RoselineMCP**) hard-fails; recommended capabilities (context7 MCP, gh, node, headless Chrome, frontend-design/dataviz skills) degrade **loudly** — every absence is recorded in the report with the fallback used.

## Safety rails

- Dedicated `migration/<date>` branch; commit at every green gate.
- All RoselineMCP mutations run **preview-first**; diffs are inspected before `previewOnly: false`.
- A failed gate stops forward progress — fix or roll back, never skip.

## Repository layout

```
.claude-plugin/         plugin + marketplace manifests
commands/               /migrate, /migrate-assess, /migrate-verify, /migrate-audit
skills/legacy-upgrade/  the pipeline orchestrator + phase references + playbooks
scripts/                preflight.sh (phase-0 gate) · audit-inventory.sh (JSON inventory) · report-dashboard.py (report generator)
templates/              ci-dotnet.yml + deploy-pages-blazor.yml — CI/deployment a migration drops into the target repo
samples/LegacyShop/     deliberately-legacy .NET solution (demo fixture, CI-guarded)
docs/case-studies/      real audits and migrations, with generated dashboards
docs/demo-walkthrough.md  a real pipeline run, with captured RoselineMCP output
```

**Live proof:** [play the wave-1 migrated game](https://phmatray.github.io/winrt-sokoban/) — a 2014 WinRT app, dead since Windows 8.x, now a Blazor WASM PWA.

## Proof it works

See [docs/demo-walkthrough.md](docs/demo-walkthrough.md): a genuine run of the pipeline migrating `samples/LegacyShop` from out-of-support **net6.0** to **net10.0**, with real RoselineMCP diagnostics before/after and green tests at the end.
