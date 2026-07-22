# AI Migration Kit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the ai-migration-kit Claude Code plugin — a six-phase legacy-app upgrade pipeline powered by RoselineMCP — with a legacy .NET sample and a real, captured demo run proving it works.

**Architecture:** A Claude Code plugin (skills + commands, all markdown) encoding the pipeline; RoselineMCP is the mandatory engine for C# analysis/transformation. A deliberately-legacy sample solution (`samples/LegacyShop`, net6.0) is the demo fixture; the pipeline is executed for real against a scratch copy and the evidence captured in `docs/demo-walkthrough.md`.

**Tech Stack:** Claude Code plugin format (plugin.json, commands/*.md, skills/*/SKILL.md), RoselineMCP (analyze_solution, list_diagnostics, apply_fixes, edit_member, rename_symbol, find_references, get_call_graph, get_symbol_at_position, search_symbols), .NET SDK 6–10, xUnit.

## Global Constraints

- Every phase document MUST name the exact RoselineMCP calls it uses (spec success criterion).
- All RoselineMCP mutations are preview-first (`previewOnly` defaults true; apply is an explicit second call).
- A red gate (build/test failure) stops forward progress — never skip to the next phase.
- Sample fixture targets `net6.0` (out of support) and stays legacy in-repo; migration target default is latest LTS (`net10.0` here).
- Commit at every green gate.

---

### Task 1: Plugin scaffold (manifest, marketplace, README)

**Files:**
- Create: `.claude-plugin/plugin.json`
- Create: `.claude-plugin/marketplace.json`
- Create: `README.md`

**Interfaces:**
- Produces: plugin name `ai-migration-kit`; command names `/migrate`, `/migrate-assess`, `/migrate-verify`; skill name `legacy-upgrade` — all later tasks must match these exactly.

- [ ] **Step 1: Write plugin.json**

```json
{
  "name": "ai-migration-kit",
  "displayName": "AI Migration Kit",
  "version": "1.0.0",
  "description": "Complete, verified, easy and fast upgrades of legacy .NET applications, powered by RoselineMCP (Roslyn). Six-phase pipeline: assess, baseline, retarget, remediate, modernize, verify.",
  "author": { "name": "Philippe Matray" },
  "keywords": ["migration", "legacy", "dotnet", "csharp", "roslyn", "roseline", "upgrade"]
}
```

- [ ] **Step 2: Write marketplace.json** (owner `phmatray`, one plugin entry pointing at repo root `./`).

- [ ] **Step 3: Write README.md** with: French tagline (the goal verbatim), what the kit is, prerequisites (Claude Code, RoselineMCP server configured, .NET SDK), install via marketplace add + plugin install, quickstart (`/migrate-assess` then `/migrate`), pipeline table (6 phases, gate per phase, RoselineMCP tools per phase), safety rails, repo layout, link to demo walkthrough.

- [ ] **Step 4: Verify JSON validity**

Run: `python3 -m json.tool .claude-plugin/plugin.json && python3 -m json.tool .claude-plugin/marketplace.json`
Expected: both print parsed JSON, exit 0.

- [ ] **Step 5: Commit** — `feat: plugin scaffold (manifest, marketplace, README)`

### Task 2: Orchestrator skill + Roseline playbook

**Files:**
- Create: `skills/legacy-upgrade/SKILL.md`
- Create: `skills/legacy-upgrade/references/roseline-playbook.md`

**Interfaces:**
- Consumes: names from Task 1.
- Produces: phase reference filenames `phase-1-assess.md` … `phase-6-verify.md` (Task 3 must create exactly these); artifact paths `migration/assessment.md`, `migration/baseline.md`, `migration/report.md` used by commands and phases.

- [ ] **Step 1: Write SKILL.md** — frontmatter (`name: legacy-upgrade`, trigger-rich `description`), then: mission; hard rules (RoselineMCP mandatory for C# analysis/mutation, preview-first, red gate stops, branch `migration/<yyyy-mm-dd>`, commit per green gate); the six-phase pipeline as a table (phase, purpose, gate, reference file); instruction to load `references/phase-N-*.md` on demand; artifact contract (`migration/` folder in target repo).

- [ ] **Step 2: Write roseline-playbook.md** — task→tool mapping table covering every tool: solution health → `analyze_solution`; enumerate fixable issues → `list_diagnostics`; bulk mechanical fix → `apply_fixes` (preview → apply); replace/add/delete one member → `edit_member`; API rename → `rename_symbol`; blast-radius before change → `find_references`; who-calls/what-calls → `get_call_graph`; resolve file:line from build error → `get_symbol_at_position`; find/inspect symbol → `search_symbols` / `get_symbol_info`; hierarchy questions → `get_type_hierarchy` / `find_implementations`; diff-only edits → `create_patch`. Include when-NOT-to (non-C# files → plain tools).

- [ ] **Step 3: Commit** — `feat: legacy-upgrade orchestrator skill + Roseline playbook`

### Task 3: Six phase reference files

**Files:**
- Create: `skills/legacy-upgrade/references/phase-1-assess.md`
- Create: `skills/legacy-upgrade/references/phase-2-baseline.md`
- Create: `skills/legacy-upgrade/references/phase-3-retarget.md`
- Create: `skills/legacy-upgrade/references/phase-4-remediate.md`
- Create: `skills/legacy-upgrade/references/phase-5-modernize.md`
- Create: `skills/legacy-upgrade/references/phase-6-verify.md`

**Interfaces:**
- Consumes: playbook tool names, artifact paths from Task 2.
- Produces: per-phase entry criteria / steps / exact RoselineMCP calls / exit gate.

- [ ] **Step 1: Write each phase file** with the uniform structure **Entry criteria → Steps → RoselineMCP calls (exact tool names, key params) → Exit gate → Rollback**:
  - P1 Assess (read-only): inventory TFMs/packages via csproj read + `analyze_solution` (maxDiagnostics, severity=Warning), shape via `search_symbols`; write `migration/assessment.md` (projects table, diagnostics histogram, risk map, recommended target TFM = latest LTS). Gate: assessment written, no files touched.
  - P2 Baseline: `dotnet build` + `dotnet test`; characterization tests for untested critical paths found via `get_call_graph` (direction=callers, depth=2); record counts in `migration/baseline.md`. Gate: green build+tests, baseline committed.
  - P3 Retarget: dependency-order TFM bump (leaf libs first), package updates, SDK-style conversion if needed; per-project rebuild; break sites via `get_symbol_at_position` (file+line from build error) then `find_references` before touching shared APIs. Gate: solution builds on new TFM.
  - P4 Remediate: `list_diagnostics` grouped by ID; mechanical IDs in bulk via `apply_fixes` preview → inspect diff → `previewOnly:false`; judgment fixes via `edit_member` (replace); obsolete-API swaps listed (WebClient→HttpClient, BinaryFormatter→System.Text.Json, etc.). Loop until errors=0, warnings ≤ baseline. Gate: tests green.
  - P5 Modernize (opt-in): nullable enable, ImplicitUsings, file-scoped namespaces, async end-to-end; each preceded by `find_references` impact check; renames only via `rename_symbol` (preview → apply). Gate: build+tests green after each item.
  - P6 Verify: full rebuild, full tests, `analyze_solution` compared to baseline (errors 0, warnings ≤ baseline), write `migration/report.md` (before/after TFM+package+diagnostics tables, changes list, follow-ups). Gate: report written, all green.

- [ ] **Step 2: Verify success criterion** — grep each phase file for at least one `mcp` tool name or explicit Roseline call name.

Run: `grep -L 'analyze_solution\|list_diagnostics\|apply_fixes\|edit_member\|rename_symbol\|find_references\|get_call_graph\|get_symbol_at_position\|search_symbols' skills/legacy-upgrade/references/phase-*.md`
Expected: no output (every file names at least one tool).

- [ ] **Step 3: Commit** — `feat: six phase reference guides`

### Task 4: Slash commands

**Files:**
- Create: `commands/migrate.md`
- Create: `commands/migrate-assess.md`
- Create: `commands/migrate-verify.md`

**Interfaces:**
- Consumes: skill name `legacy-upgrade`, phase files, artifact paths.

- [ ] **Step 1: Write the three commands** — each with frontmatter `description` and `argument-hint: [path-to-solution]`; body instructs: invoke the `legacy-upgrade` skill, scope (`/migrate` = phases 1–6; `/migrate-assess` = phase 1 only, read-only guarantee stated; `/migrate-verify` = phase 6 only, re-runnable), `$ARGUMENTS` = optional solution path (default: auto-discover).

- [ ] **Step 2: Commit** — `feat: /migrate, /migrate-assess, /migrate-verify commands`

### Task 5: LegacyShop sample (deliberately legacy, but green)

**Files:**
- Create: `samples/LegacyShop/LegacyShop.sln`
- Create: `samples/LegacyShop/src/LegacyShop.Domain/LegacyShop.Domain.csproj` (net6.0, no nullable, no implicit usings)
- Create: `samples/LegacyShop/src/LegacyShop.Domain/Order.cs`, `OrderItem.cs`, `OrderService.cs`, `PriceCatalogClient.cs` — block namespaces, `WebClient`, sync-over-async, string-based status, manual null checks
- Create: `samples/LegacyShop/src/LegacyShop.App/LegacyShop.App.csproj` + `Program.cs` (classic `static void Main`)
- Create: `samples/LegacyShop/tests/LegacyShop.Tests/LegacyShop.Tests.csproj` (xunit 2.4.x) + `OrderServiceTests.cs` (≥4 characterization tests: totals, discount rule, status transition, null rejection)
- Create: `samples/LegacyShop/README.md` (what's deliberately wrong + how to run the kit on it)

**Interfaces:**
- Produces: a solution that builds and tests green on net6.0 and emits legacy-pattern warnings (SYSLIB0014 WebClient) for the demo to fix.

- [ ] **Step 1: Scaffold projects with `dotnet new` + write the legacy source.** Representative legacy idiom (PriceCatalogClient.cs):

```csharp
using System;
using System.Net;

namespace LegacyShop.Domain
{
    public class PriceCatalogClient
    {
        public string DownloadCatalog(string url)
        {
            using (var client = new WebClient())
            {
                return client.DownloadString(url); // SYSLIB0014, sync-over-async
            }
        }
    }
}
```

- [ ] **Step 2: Verify fixture is green-but-legacy**

Run: `cd samples/LegacyShop && dotnet build -warnaserror- && dotnet test --nologo`
Expected: Build succeeded (with SYSLIB0014 warnings), all tests pass.

- [ ] **Step 3: Commit** — `feat: LegacyShop legacy sample fixture (net6.0)`

### Task 6: Real demo run + walkthrough + final verify

**Files:**
- Create: `docs/demo-walkthrough.md`
- Modify: `README.md` (link walkthrough results)

**Interfaces:**
- Consumes: everything above; scratch copy of `samples/LegacyShop` outside the repo.

- [ ] **Step 1: Copy fixture to scratchpad**, `git init` there, run the six phases for real using RoselineMCP tools (`analyze_solution` baseline → retarget csproj to net10.0 → `list_diagnostics` → `apply_fixes`/`edit_member` for WebClient→HttpClient etc. → `dotnet test` green → final `analyze_solution`).

- [ ] **Step 2: Capture genuine outputs** (diagnostic counts before/after, a real `apply_fixes`/`edit_member` diff, final green test run) into `docs/demo-walkthrough.md`, phase by phase.

- [ ] **Step 3: Run the spec success-criteria checklist** (plugin files valid, commands present, phase files name tools, demo green) and record results in the walkthrough.

- [ ] **Step 4: Commit** — `docs: real RoselineMCP demo run on LegacyShop (net6.0 → net10.0)`
