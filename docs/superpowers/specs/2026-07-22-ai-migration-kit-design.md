# AI Migration Kit — Design

**Date:** 2026-07-22
**Goal:** « Mise à niveau complète, parfaite, facile et rapide de n'importe quelle application legacy » — powered by RoselineMCP.

## Problem

Upgrading a legacy application (out-of-support target framework, outdated packages, obsolete APIs, legacy idioms) is slow, risky, and expertise-heavy. Teams need a repeatable process that is:

- **Complète** — covers assessment through verified delivery, not just the csproj bump.
- **Parfaite** — every step is verified (build, tests, diagnostics baseline); no silent regressions.
- **Facile** — one command starts the whole pipeline.
- **Rapide** — bulk mechanical fixes are automated; only judgment calls take agent time.

## Decision

Ship **ai-migration-kit** as a Claude Code plugin. The plugin encodes a six-phase migration pipeline as a skill plus slash commands. RoselineMCP (Roslyn-powered MCP server) is the mandatory engine for all C# analysis and code transformation: solution diagnostics, bulk code fixes, surgical member edits, safe renames, and impact analysis via references/call graphs.

The kit's methodology is framework-agnostic (assess → baseline → retarget → remediate → modernize → verify), with a deep, tool-backed path for .NET/C# — the dominant legacy-app case RoselineMCP serves.

### Alternatives rejected

- **Standalone orchestrator CLI** — duplicates the agent loop Claude Code already provides; high build cost, brittle.
- **Docs-only playbook** — leaves the user hand-driving every step; neither easy nor fast, and doesn't operationalize RoselineMCP.

## Architecture

```
ai-migration-kit/
├── .claude-plugin/
│   ├── plugin.json              # plugin manifest
│   └── marketplace.json         # local/git marketplace for easy install
├── README.md                    # quickstart, pipeline overview
├── commands/
│   ├── migrate.md               # /migrate — run the full pipeline
│   ├── migrate-assess.md        # /migrate-assess — read-only audit report
│   └── migrate-verify.md        # /migrate-verify — post-migration quality gate
├── skills/
│   └── legacy-upgrade/
│       ├── SKILL.md             # orchestrator: the six-phase pipeline
│       └── references/
│           ├── roseline-playbook.md   # which RoselineMCP tool for which job
│           ├── phase-1-assess.md
│           ├── phase-2-baseline.md
│           ├── phase-3-retarget.md
│           ├── phase-4-remediate.md
│           ├── phase-5-modernize.md
│           └── phase-6-verify.md
├── samples/
│   └── LegacyShop/              # deliberately-legacy .NET solution (demo fixture)
└── docs/
    ├── demo-walkthrough.md      # real pipeline run on LegacyShop, captured output
    └── superpowers/specs|plans/ # this spec + the implementation plan
```

### Components

**Skill `legacy-upgrade` (orchestrator).** One clear purpose: given a target repo, drive the six phases in order, never advancing on a red gate. It loads per-phase reference files on demand so context stays small. Interface: invoked by the slash commands (or directly). Depends on: RoselineMCP tools, git, the target's build/test toolchain.

**Phase references.** Each phase file answers: entry criteria, steps, RoselineMCP calls to use, exit gate. Independent and individually readable.

**Roseline playbook.** A task→tool mapping (e.g., "compile errors after retarget → `list_diagnostics` + `get_symbol_at_position`; mechanical fix IDs → `apply_fixes` preview → apply; API rename → `rename_symbol`"). Keeps phase files DRY.

**Slash commands.** Thin entry points: `/migrate` (full pipeline), `/migrate-assess` (phase 1 only, read-only — safe first contact), `/migrate-verify` (phase 6 only — re-runnable gate).

**Sample `LegacyShop`.** Small multi-project solution (domain lib + console app + tests) targeting out-of-support net6.0 with deliberate legacy idioms (block namespaces, no nullable annotations, `WebClient`, sync-over-async, obsolete APIs). Serves as demo fixture and regression test for the kit itself.

## The Pipeline (data flow)

1. **Assess** *(read-only)* — `analyze_solution` + `search_symbols`: inventory projects, TFMs, packages, diagnostics counts; produce `migration/assessment.md` with a risk map and target recommendation (default: latest LTS).
2. **Baseline** — build + run tests; record diagnostic counts as the baseline contract. If no tests cover a critical path (found via `get_call_graph`), add characterization tests first.
3. **Retarget** — bump TFMs/SDK-style projects/packages, innermost project first; rebuild after each. Break sites resolved with `get_symbol_at_position` → `find_references`.
4. **Remediate** — `list_diagnostics` → group by ID → `apply_fixes` (preview, then apply) for mechanical IDs; `edit_member` for surgical fixes. Loop until errors = 0.
5. **Modernize** — opt-in idiom upgrades (nullable, file-scoped namespaces, async, DI), each preceded by `find_references` impact analysis.
6. **Verify** — build green, tests green, diagnostics ≤ baseline, `migration/report.md` written.

**Safety rails (error handling):** dedicated `migration/<date>` git branch; commit at every green gate; all RoselineMCP mutations run preview-first; a red gate stops forward progress — fix or roll back, never skip.

## Testing

The kit is validated by running it for real: execute the pipeline against a scratch copy of `LegacyShop` using RoselineMCP, and capture the genuine tool outputs in `docs/demo-walkthrough.md` (before/after diagnostics, applied fixes, final green verify). The fixture stays legacy in-repo so the demo is reproducible.

## Success criteria

- Plugin installs and `/migrate-assess`, `/migrate`, `/migrate-verify` are available.
- The demo run migrates LegacyShop net6.0 → net10.0 with build + tests green and captured evidence.
- Every phase document names the exact RoselineMCP calls it uses.
