# Phase 1 — Assess (read-only)

**Entry criteria:** target repo identified; RoselineMCP reachable; git status clean.

## Steps

1. Locate the solution: `find . -name '*.sln'` (or the path given in `$ARGUMENTS`).
   **Then run `dotnet restore` before any analysis** — an unrestored solution makes `analyze_solution` report hundreds of false "type 'System' could not be found" errors (restore only reads/writes `obj/`, so the read-only guarantee holds). **If restore itself fails, capture the error IDs verbatim** — a failing restore is a signal, not a dead end (see the verdict, step 6): `NU1202 package X supports netN.0` against a project on `netM.0` (M<N) is the `RED_BY_TFM_LAG` fingerprint, not a reason to stop.
2. Inventory projects: Read each `.csproj` — record TFM(s), SDK style (SDK-style vs legacy), `PackageReference`/`packages.config`, project references. Build a dependency order (leaf libraries first).
3. Solution health: `analyze_solution` with `pathOrGit: <sln>`, `severity: "Warning"`, `maxDiagnostics: 100`. Record error/warning/info counts and the top diagnostic IDs.
4. Shape: `search_symbols` for entry points and public surface size; note test projects and framework (xUnit/NUnit/MSTest) or their absence. **Record the exact test stack, not just the framework name** — run `<kit>/scripts/audit-inventory.sh <repo>` and copy its `testStack[]` into the assessment: per test project, the TFM(s), every package id + version, and `xunitMajor`. The major line matters because moving xunit v2 → v3 is a **package-id change** (`xunit` → `xunit.v3`) that `dotnet list package --outdated` can never propose; without this line written down, phase 3 bumps to the latest v2 and the decision is made by accident. Phase 5 owns the decision (`references/xunit-v3-migration.md`).
5. Risk map: flag out-of-support TFMs, obsolete-API warnings (`SYSLIB*`), `packages.config`, `WebClient`/`BinaryFormatter`/`AppDomain` usage (locate with `find_references` on the suspect types), projects with zero test coverage.
   **Also read `vendoredAssets[]` from the same `audit-inventory.sh` run** — front-end libraries dropped into `wwwroot/lib/` or `wwwroot/vendor/` by hand. Both a per-library directory and a loose file (`wwwroot/lib/htmx.min.js`) count, and so does a git submodule sitting in that directory — the least-watched shape of the three, since Renovate's `git-submodules` manager is off by default and Dependabot's `gitsubmodule` ecosystem must be opted into.
   **It is a census, not a findings list**, so a non-empty array is not by itself a problem. Each entry carries `coveredByManifest`, and `coveredBy` naming the manifest when one covers it:
   - **`coveredByManifest: false` → the risk map.** Nothing watches these: Renovate opens no PR, Dependabot raises no advisory, so a CVE there is not *unfixed* but **unseen**, on a repo whose CI is green and whose Dependency Dashboard is quiet. Measured across 193 .NET repos: 17 carry a vendored copy, and **none of the 38 directories was covered by a manifest** — so on a legacy target, expect this subset to be all of them.
   - **`coveredByManifest: true` → the de-vendoring precedent, not a finding.** `coveredBy` names a `package.json` or `libman.json` in the repo that already declares a library correctly. Cite it when you propose de-vendoring the others: the pattern exists here, in that file, and the work is to extend it rather than introduce it.
   `[]` still means "measured, nothing vendored at all" — never "not measured".
   This phase is the last point where the finding can still change the plan (de-vendor to npm/LibMan, or accept and record why); the kit deliberately does *not* add a CI step that would report it forever afterwards.
   Two things the key does **not** claim. It never resolves versions or checks a CVE feed — the finding is "this exists and nothing watches it", not "this is vulnerable". And it only sees what the walk reaches: `node_modules/`, `bin` and `obj` are never searched, and neither is a **nested checkout** (a directory with its own `.git` — an agent worktree, a submodule, a vendored clone) or a **restored NuGet package** under `packages/`.
   **Read `excludedFromWalk[]` before trusting any count.** It lists every directory the walk dropped by decision, with the reason, precisely so a smaller number is explicable rather than mysterious. This matters in both directions: a submodule can hold first-party code you are migrating, and a `packages/` directory can hold the apps rather than restore output — the audit decides per directory from its shape, and tells you what it decided. `csFiles`, `locTotal`, `projects` and `testStack` all obey the same walk, so an entry here explains all of them at once.
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
