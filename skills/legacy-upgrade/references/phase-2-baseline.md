# Phase 2 — Baseline

**Entry criteria:** phase 1 assessment approved; migration branch `migration/<yyyy-mm-dd>` created.

## Steps

1. Prove green: `dotnet build` then `dotnet test` on the **current** (legacy) TFM. If the build is already red, stop — fixing the legacy build is a prerequisite task, not part of the migration. **Exception — `verdict: RED_BY_TFM_LAG` (from phase 1):** the baseline *cannot* be green here because the TFM lags its packages (restore fails with `NU1202` before any change), and the retarget is the fix, not something a green baseline must precede. Do **not** stop and do **not** force the legacy TFM green. Record `baseline: deferred to phase 3 (RED_BY_TFM_LAG — retarget is the prerequisite)` in `migration/baseline.md` with the captured `NU1202` signature, then let phase 3 capture the first post-retarget green as the real baseline.
2. Coverage check on critical paths: for each entry point / core service method from the assessment, `get_call_graph` with `direction: "callers"`, `depth: 2` — if a core method has no test among its callers, write a **characterization test** (assert current behavior exactly as-is, even if odd; quirks become follow-ups, not fixes).
3. Record the contract in `migration/baseline.md`:
   - build result, test count + pass count,
   - `analyze_solution` error/warning counts (this is the number phase 4 and 6 gates compare against),
   - exact SDK/tool versions (`dotnet --version`).
4. Commit: `migration: phase 2 baseline (N tests green, E errors / W warnings)`.

## RoselineMCP calls

`get_call_graph` (find untested critical paths), `analyze_solution` (diagnostic baseline).

## Exit gate

Build green, all tests green, `migration/baseline.md` committed. **For `RED_BY_TFM_LAG` this gate is *deferred*:** phase 2 commits only the deferral record; the green-baseline gate is satisfied at the end of phase 3 (first green on the new TFM), and phases 4 and 6 compare against *that* baseline.

## Rollback

Delete added characterization tests only if they are wrong (asserting intended rather than actual behavior); the baseline itself is read-only observation.
