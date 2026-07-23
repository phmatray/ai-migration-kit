# Phase 3 — Retarget

**Entry criteria:** phase 2 gate green — or *deferred* for `verdict: RED_BY_TFM_LAG`, where phase 2 could not reach a green baseline because the TFM lagged its packages (see phase 2, step 1); dependency order of projects known from the assessment.

## Steps

1. **Order:** leaf libraries first, then their consumers, apps last, test projects alongside the project they test.
2. Per project, innermost first:
   a. If legacy-style project: convert to SDK-style csproj first (smallest faithful conversion — keep TFM, references, and settings identical; `packages.config` → `PackageReference`).
   b. Bump `<TargetFramework>` to the chosen target (e.g. `net10.0`).
   c. Update packages: `dotnet list package --outdated`, then bump — prefer the latest version compatible with the target TFM; major bumps get their release notes checked.
   d. `dotnet build` **this project only**. Fix breaks before moving on.
3. **Break triage:** for each build error `File.cs(L,C): error CSxxxx` → `get_symbol_at_position(file, L)` to identify the symbol → `get_symbol_info` for its signature/docs. If the fix touches an API used elsewhere, run `find_references` first and apply the change bottom-up. Use `edit_member` (preview → apply) for the code change.
4. After all projects: full `dotnet build` at solution level, then `dotnet test`.
5. Commit per green project: `migration: phase 3 retarget <Project> -> <tfm>`.
6. **Deferred baseline (`verdict: RED_BY_TFM_LAG` only).** The first green solution-level build + test on the new TFM **is** the baseline phase 2 deferred: record it now in `migration/baseline.md` (build result, test count + pass count, `analyze_solution` error/warning counts, `dotnet --version`) and commit `migration: phase 3 baseline captured post-retarget (N tests green, E errors / W warnings)`. Phases 4 and 6 compare against these numbers. (For `NORMAL`, the baseline already exists from phase 2 — skip this step.)

## RoselineMCP calls

`get_symbol_at_position` (resolve build-error locations), `get_symbol_info`, `find_references` (blast radius before shared-API changes), `edit_member` (surgical break fixes, preview first).

## Exit gate

Entire solution builds on the new TFM; tests run (failures triaged: environment/API breaks fixed, genuine behavior differences investigated before proceeding).

## Rollback

Per-project commits mean a bad retarget is `git revert`/`git reset` of the last commit only; never batch multiple projects into one commit.
