# Phase 6 — Verify

**Entry criteria:** phases 3–5 complete (or `/migrate-verify` invoked standalone on a migrated branch).

## Steps

1. Clean rebuild: `dotnet clean && dotnet build` — must be green with zero errors.
2. Full test run: `dotnet test` — all green; count ≥ the phase-2 baseline count (tests were added, never removed).
3. Final health: `analyze_solution` (`severity: "Warning"`) — compare against `migration/baseline.md`: **errors = 0, warnings ≤ baseline**.
4. Runtime smoke test: run the app's entry point(s) the same way the baseline did; confirm equivalent observable behavior.
5. Write `migration/report.md` following `report-template.md` (sections obligatoires, dont **Prochaines étapes** en checklist actionnable) :
   - Before/after table: TFM, SDK style, package versions (use `create_patch` on the old vs new csproj text for an exact diff appendix),
   - Diagnostics: baseline counts vs final counts,
   - Tests: baseline vs final (count, all green),
   - Changes: chronological commit list of the migration branch (`git log --oneline`),
   - **Next steps**: ordered, actionable checklist to production (merge, deploy, CI, owner decisions) with effort hints,
   - Follow-ups: behavior quirks found (from characterization tests), deferred modernizations, packages held back and why.
6. **Phase timeline — measured, never hand-timed.** Derive per-phase timings from the green-gate
   commits of the migration branch (`git log --reverse --format='%cI %s'` — each gate commit names
   its phase, rule 4; a phase starts when the previous gate closed) and write them to
   `migration/report.json` as `phases[]`:
   `{"phase": <n>, "name": "<Phase>", "start": "<ISO 8601>", "end": "<ISO 8601>", "minutes": <n>}`.
   `report-dashboard.py` renders the timeline card; the kit's advertised pipeline minutes are
   quoted from here — a generated fact, not a stopwatch.
7. Final commit: `migration: phase 6 verified — report`.

## RoselineMCP calls

`analyze_solution` (final gate), `create_patch` (before/after csproj diff for the report).

## Exit gate

All of: clean build green, tests green and ≥ baseline count, errors 0, warnings ≤ baseline, `migration/report.md` committed. Only now is the migration **complete**.

## Rollback

If any check fails, the pipeline returns to the phase that owns the failure (build → 3, diagnostics → 4, tests → 2/4); the report is written only after everything is green.
