# Phase 1 — Assess (read-only)

**Entry criteria:** target repo identified; RoselineMCP reachable; git status clean.

## Steps

1. Locate the solution: `find . -name '*.sln'` (or the path given in `$ARGUMENTS`).
   **Then run `dotnet restore` before any analysis** — an unrestored solution makes `analyze_solution` report hundreds of false "type 'System' could not be found" errors (restore only reads/writes `obj/`, so the read-only guarantee holds).
2. Inventory projects: Read each `.csproj` — record TFM(s), SDK style (SDK-style vs legacy), `PackageReference`/`packages.config`, project references. Build a dependency order (leaf libraries first).
3. Solution health: `analyze_solution` with `pathOrGit: <sln>`, `severity: "Warning"`, `maxDiagnostics: 100`. Record error/warning/info counts and the top diagnostic IDs.
4. Shape: `search_symbols` for entry points and public surface size; note test projects and framework (xUnit/NUnit/MSTest) or their absence.
5. Risk map: flag out-of-support TFMs, obsolete-API warnings (`SYSLIB*`), `packages.config`, `WebClient`/`BinaryFormatter`/`AppDomain` usage (locate with `find_references` on the suspect types), projects with zero test coverage.
6. Recommend a target: latest LTS TFM unless the user specified one; list packages needing major-version bumps.
7. Write `migration/assessment.md`: projects table (name, TFM, style, packages), diagnostics histogram, risk map, recommended target + estimated phase-3 order.

## RoselineMCP calls

`analyze_solution`, `search_symbols`, `find_references` (all read-only).

## Exit gate

`migration/assessment.md` exists; `git status` shows **no modified files** (only the new assessment file). If running `/migrate-assess`, stop here and present the assessment.

## Rollback

Nothing to roll back — this phase must not modify anything.
