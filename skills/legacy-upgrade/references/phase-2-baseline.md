# Phase 2 — Baseline

**Entry criteria:** phase 1 assessment approved; migration branch `migration/<yyyy-mm-dd>` created.

## Steps

1. Prove green: `dotnet build` then `dotnet test` on the **current** (legacy) TFM. If the build is already red, stop — fixing the legacy build is a prerequisite task, not part of the migration.
2. Coverage check on critical paths: for each entry point / core service method from the assessment, `get_call_graph` with `direction: "callers"`, `depth: 2` — if a core method has no test among its callers, write a **characterization test** (assert current behavior exactly as-is, even if odd; quirks become follow-ups, not fixes).
3. Record the contract in `migration/baseline.md`:
   - build result, test count + pass count,
   - `analyze_solution` error/warning counts (this is the number phase 4 and 6 gates compare against),
   - exact SDK/tool versions (`dotnet --version`).
4. Commit: `migration: phase 2 baseline (N tests green, E errors / W warnings)`.

## RoselineMCP calls

`get_call_graph` (find untested critical paths), `analyze_solution` (diagnostic baseline).

## Exit gate

Build green, all tests green, `migration/baseline.md` committed.

## Rollback

Delete added characterization tests only if they are wrong (asserting intended rather than actual behavior); the baseline itself is read-only observation.
