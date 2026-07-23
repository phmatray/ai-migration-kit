# Phase 1 — Assess (read-only)

**Entry criteria:** target repo identified; RoselineMCP reachable; git status clean.

## Steps

1. Locate the solution: `find . -name '*.sln'` (or the path given in `$ARGUMENTS`).
   **Then run `dotnet restore` before any analysis** — an unrestored solution makes `analyze_solution` report hundreds of false "type 'System' could not be found" errors (restore only reads/writes `obj/`, so the read-only guarantee holds). **If restore itself fails, capture the error IDs verbatim** — a failing restore is a signal, not a dead end (see the verdict, step 6): `NU1202 package X supports netN.0` against a project on `netM.0` (M<N) is the `RED_BY_TFM_LAG` fingerprint, not a reason to stop.
2. Inventory projects: Read each `.csproj` — record TFM(s), SDK style (SDK-style vs legacy), `PackageReference`/`packages.config`, project references. Build a dependency order (leaf libraries first).
3. Solution health: `analyze_solution` with `pathOrGit: <sln>`, `severity: "Warning"`, `maxDiagnostics: 100`. Record error/warning/info counts and the top diagnostic IDs.
4. Shape: `search_symbols` for entry points and public surface size; note test projects and framework (xUnit/NUnit/MSTest) or their absence.
5. Risk map: flag out-of-support TFMs, obsolete-API warnings (`SYSLIB*`), `packages.config`, `WebClient`/`BinaryFormatter`/`AppDomain` usage (locate with `find_references` on the suspect types), projects with zero test coverage.
6. **Verdict — the phase-1 gate.** Classify the target into exactly one state; this is what `/migrate` branches on:
   - **`ALREADY_MODERN`** — every TFM is already at the target (latest LTS unless the user named one) **and** no out-of-support runtime **and** no obsolete-API cluster (`SYSLIB*`, `packages.config`, `BinaryFormatter`). There is nothing to migrate. Recommended target = *"none — already up to date"*. Modern ≠ clean, so the app can still want a quality gate: route to `/migrate-verify` (phase 6), never a net`N`→net`N` retarget.
   - **`RED_BY_TFM_LAG`** — the legacy build/restore is red **because a bot (e.g. Renovate) pushed the package graph past the TFM**: the `NU1202 package X supports netN.0` on `netM.0` (M<N) fingerprint from step 1. The retarget is the *prerequisite* for a green restore, not something a green baseline must precede — phase 2 records the baseline as deferred, phase 3 captures the first post-retarget green as the baseline.
   - **`NORMAL`** — anything else (obsolete TFM, obsolete-API clusters, legacy-style projects that restore green on their current TFM): the standard baseline-green-first path.
   Then recommend a target: latest LTS TFM unless the user specified one; list packages needing major-version bumps (empty for `ALREADY_MODERN`).
7. Write `migration/assessment.md`, **leading with `verdict: <ALREADY_MODERN | RED_BY_TFM_LAG | NORMAL>`** and its one-line reason, then: projects table (name, TFM, style, packages), diagnostics histogram, risk map, recommended target + estimated phase-3 order.

## RoselineMCP calls

`analyze_solution`, `search_symbols`, `find_references` (all read-only).

## Exit gate

`migration/assessment.md` exists carrying a `verdict`; `git status` shows **no modified files** (only the new assessment file). **Stop after phase 1** when running `/migrate-assess` **or** when `verdict: ALREADY_MODERN` — present the assessment and route by verdict: `ALREADY_MODERN` → offer `/migrate-verify` (a modern app can still be unclean — e.g. a high-severity transitive advisory); `RED_BY_TFM_LAG` / `NORMAL` → offer `/migrate`.

## Verdict fixtures (regression lock — real dogfood cases, 2026-07-23)

Two dogfooded runs pin the two non-`NORMAL` verdicts. Re-deriving a different verdict for either signature is a regression, not a judgment call.

- **`ALREADY_MODERN` — `Atypical-Consulting/StaticWGen`:** `net10.0` across every project, SDK pinned (`global.json` 10.0.302, `rollForward: latestFeature`), packages current (held by Renovate), no obsolete-API cluster. Verdict `ALREADY_MODERN`; `/migrate` stops after phase 1. The one successful `dotnet restore` still surfaced `NU1903` — a high-severity transitive advisory in `System.Security.Cryptography.Xml` 9.0.0 — proving modern ≠ clean and why the route is `/migrate-verify`, not "done".
- **`RED_BY_TFM_LAG` — `phmatray/DotnetChain`:** `net9.0` projects carrying EF Core 10 / ASP.NET 10 packages (net10-only) pushed by Renovate → `NU1202`, restore impossible before any migration. Verdict `RED_BY_TFM_LAG`; the net9→net10 retarget is the baseline prerequisite (PR #64, 88 tests green after retarget). Making the long-red build compile also exposed pre-existing, framework-unrelated breakage (a half-finished domain refactor, 536 CS errors) — the pipeline repairs everything verifiable and names the edges (rules 5 + 9) without inventing the missing behavior.

## Rollback

Nothing to roll back — this phase must not modify anything.
