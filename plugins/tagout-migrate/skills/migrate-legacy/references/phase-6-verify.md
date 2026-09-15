# Phase 6 — Verify

**Entry criteria:** phases 3–5 complete (or `/migrate-verify` invoked standalone on a migrated branch).

## Steps

1. Clean rebuild: `dotnet clean && dotnet build` — must be green with zero errors.
2. Full test run, collecting coverage into `coverage/` the way `templates/ci-dotnet.yml`'s "Tests + couverture" step does — the command depends on the test platform phase 1 already recorded (`testStack[].xunitMajor`): **Microsoft Testing Platform**, only once the phase-5 xunit.v3 item ran — `dotnet test --nologo -- --coverage --coverage-output-format cobertura --results-directory "$PWD/coverage"`; **VSTest**, the default when it did not — `dotnet test --nologo --collect:"XPlat Code Coverage" --results-directory "$PWD/coverage"`. Using the MTP form on a VSTest project (or vice versa) collects nothing: the run stays green, but `--coverage`/`--collect:` is silently ignored by the wrong host and `coverage/` never gets created — phase 6 then dies at the report step (step 6) with no earlier warning. All green; count ≥ the phase-2 baseline count (tests were added, never removed). **Record the counted number and the test platform** (VSTest, or Microsoft Testing Platform when the phase-5 xunit.v3 item ran) — a test count is only meaningful next to the host that produced it, and this is the number that proves the suite still executes rather than merely compiles.
3. Final health: `analyze_solution` (`severity: "Warning"`) — compare against `migration/baseline.md`: **errors = 0, warnings ≤ baseline**.
4. **Dependency health — the graph phase 3 rewrote.** Run `<kit>/scripts/dependency-health.sh <repo | solution | project>` (a directory, a `.sln`, or a `.csproj` — name the solution explicitly when the repo root holds more than one, or MSBuild refuses to guess) and write the `dependencyHealth` object it prints on stdout into `migration/report.json` as a top-level key. It runs `dotnet list package --vulnerable --include-transitive --format json` and `dotnet list package --deprecated --include-transitive --format json`; `--include-transitive` is the load-bearing half on both legs, because that is where the exposure the customer never chose actually lives. **Findings do not fail this gate — a missing or `unavailable` block does.** A CVE in a transitive dependency is frequently not fixable inside the migration's scope, so a finding travels to the owner as a row in *Prochaines étapes* / *Suivis* (step 6) rather than turning a legitimately-complete migration red; what is not negotiable is that the check RAN, because a check that cannot verify must not answer "healthy" — an empty `vulnerable[]` from a `dotnet` that never executed is byte-identical to a clean graph. The script exits 1 and sets `status: "unavailable"` with a reason when it could not run (feed unreachable, restore failed, SDK below the `--format json` floor); fix the cause and re-run, never record the block without it.
5. Runtime smoke test: run the app's entry point(s) the same way the baseline did; confirm equivalent observable behavior.
6. Write `migration/report.md` following `report-template.md` (sections obligatoires, dont **Prochaines étapes** en checklist actionnable) :
   - Before/after table: TFM, SDK style, package versions (use `create_patch` on the old vs new csproj text for an exact diff appendix),
   - Diagnostics: baseline counts vs final counts,
   - Tests: baseline vs final (count, all green), **plateforme de test** (VSTest / MTP) and, when the xunit.v3 item ran or was deferred, its outcome with the blocker named,
   - Changes: chronological commit list of the migration branch (`git log --oneline`),
   - **Santé des dépendances**: the mandatory section of `report-template.md`, rendered from step 4's `dependencyHealth` block — one table row per finding (paquet · version · type · sévérité · avis), each row naming the projects it was found in (`projects[]`). Mandatory in `report.md`; `report.html` does not carry it, because `report-dashboard.py` has no `dependencyHealth` card yet and hand-written HTML is forbidden (rule 7),
   - **Next steps**: ordered, actionable checklist to production (merge, deploy, CI, owner decisions) with effort hints — **one row per `dependencyHealth.vulnerable` and `dependencyHealth.deprecated` entry**, each naming the package and the decision the owner has to take (upgrade, accept the risk, replace with the named alternative); a finding recorded in the table but absent from this checklist is a finding nobody owns,
   - Follow-ups: behavior quirks found (from characterization tests), deferred modernizations, packages held back and why — including any dependency finding the owner decided not to act on now, **with the reason**, so `review-followups` (which drains this queue) carries it forward rather than losing it.
7. **Phase timeline — measured, never hand-timed.** Derive per-phase timings from the green-gate
   commits of the migration branch (`git log --reverse --format='%cI %s'` — each gate commit names
   its phase, rule 4; a phase starts when the previous gate closed) and write them to
   `migration/report.json` as `phases[]`:
   `{"phase": <n>, "name": "<Phase>", "start": "<ISO 8601>", "end": "<ISO 8601>", "minutes": <n>}`.
   `report-dashboard.py` renders the timeline card; the kit's advertised pipeline minutes are
   quoted from here — a generated fact, not a stopwatch.
8. Final commit: `migration: phase 6 verified — report`.

## RoselineMCP calls

`analyze_solution` (final gate), `create_patch` (before/after csproj diff for the report).

## Exit gate

All of: clean build green, tests green and ≥ baseline count, errors 0, warnings ≤ baseline, `migration/report.md` committed, and a `dependencyHealth` block present in `report.json` whose status is not `unavailable`. Only now is the migration **complete**.

That last clause gates the check having RUN, never its result: `status: "findings"` passes this gate, exactly as intended (step 4). What fails it is a report that cannot say whether the delivered dependency graph was ever examined — the same way a missing coverage report already fails, and for the same reason.

## Rollback

If any check fails, the pipeline returns to the phase that owns the failure (build → 3, diagnostics → 4, tests → 2/4); the report is written only after everything is green.
