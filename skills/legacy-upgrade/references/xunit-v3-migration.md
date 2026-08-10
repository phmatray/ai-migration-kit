# Test platform — xunit v2 → xunit.v3

Loaded from **phase 5 (Modernize), extended set**. Never run this during phase 3: the retarget's
green gate must stay attributable, and a test-host swap folded into it makes a red build
impossible to blame on either change.

## Why this needs a guide at all

`dotnet list package --outdated` — what phase 3 uses to bump packages — **can never propose this
move**, because v3 is a different package *identifier*, not a newer version:

```
xunit 2.4.2  ->  --outdated says: 2.9.3      (the v2 line)
xunit 2.4.2  ->  xunit.v3 3.x               (invisible: the ID changed)
```

Dependency automation is blind for the same reason. So without an explicit decision, every
migration silently keeps the previous-generation VSTest host under a brand-new TFM — and nothing
in the pipeline reports it. Phase 1 records the line (`testStack[].xunitMajor` from
`<kit>/scripts/audit-inventory.sh`) precisely so the choice becomes visible.

## Preconditions — all four, or this item does not run

Check before touching anything. A failure is a **recorded deferral**, never a silent skip: write it
into `migration/report.md` with the blocker named, exactly as the report's follow-up section
expects.

| # | Precondition | How to check | Deferral text |
|---|---|---|---|
| 1 | Every test project targets `net8.0+` (or `net472+` on .NET Framework) | `testStack[].targetFrameworks` | `deferred: TFM below xunit.v3 floor (<tfm>)` |
| 2 | Every xunit-dependent extension package has a v3-compatible release | `testStack[].packages` + the package's nuget page | `deferred: <package> has no v3 build` |
| 3 | A phase-2 baseline test count exists | `migration/baseline.md` | `deferred: no baseline count to gate against` |
| 4 | No VSTest-only `.runsettings` drives the run | `find . -name '*.runsettings'` | `deferred: .runsettings is VSTest-only` |

Precondition 1 is why this item lives in phase 5 and not phase 3: the v3 floor is only cleared
*after* the retarget. Precondition 2 is the one that actually blocks in practice — a test project
rarely references `xunit` alone.

## Resolve the version from the live feed, never from this file

`context7` is mandatory before phase 5 anyway. Use it — or the flat index — to get the current
`xunit.v3` release rather than copying a number out of a document:

```bash
curl -s https://api.nuget.org/v3-flatcontainer/xunit.v3/index.json \
  | python3 -c "import json,sys; v=[x for x in json.load(sys.stdin)['versions'] if '-' not in x]; print(v[-1])"
```

Note the package landscape is mid-move: `xunit.v3` is the stable line; a `xunit.v3.mtp-v2` line
exists in prerelease. Pick the stable one unless the target has a reason not to.

## The csproj transform

| Change | Why |
|---|---|
| `xunit` → `xunit.v3` | package **ID** change, not a version bump |
| remove `xunit.abstractions` | merged into v3; no longer a separate package |
| remove `xunit.runner.visualstudio` | v3 ships its own Microsoft Testing Platform runner |
| remove `Microsoft.NET.Test.Sdk` | the VSTest host has no role left under MTP — unless another package still needs it |
| **add `<OutputType>Exe</OutputType>`** | **load-bearing** — v3 test projects are standalone executables |
| add `<TestingPlatformDotnetTestSupport>true</TestingPlatformDotnetTestSupport>` | keeps `dotnet test` working against an MTP project |
| **add `Microsoft.Testing.Extensions.CodeCoverage`** | **coverage does not survive the move without it** — see below |

**On the `OutputType` trap.** The documented failure mode is a v3 project left as a library, which
would compile and execute nothing. Measured on **xunit.v3 3.2.2**, the package guards this itself
and fails the build:

```
error : xUnit.net v3 test projects must be executable (set project property
        '<OutputType>Exe</OutputType>'). If this is not a test project, reference
        xunit.v3.extensibility.core instead.
```

That guard is welcome, but do not lean on it — it lives in the package's build targets, so it is a
property of the version you happen to reference, not of the migration. The **counted-tests gate
below is the contract**; the guard is a safety net that happens to be present today.

## The code transform — through RoselineMCP

Per hard rule 1, every C# mutation goes through RoselineMCP: `find_references` for the blast radius
before touching a shared type, then `edit_member` / `rename_symbol` in **preview** first (hard rule
2), then apply.

| v2 | v3 |
|---|---|
| `using Xunit.Abstractions;` for `ITestOutputHelper` | `using Xunit;` — the type moved |
| `IAsyncLifetime` returning `Task` | returns `ValueTask` |
| `ITestCaseOrderer` / `ITestCollectionOrderer` over `IEnumerable` | over `IReadOnlyCollection` |
| `ExceptionAggregator` (class, `Task` methods) | struct, `ValueTask` methods |
| `ExecutionTimer` aggregate methods | static, renamed to `Measure`, async overloads take `ValueTask` |

Most test *bodies* need no change — `Assert`, `[Fact]`, `[Theory]`, `IClassFixture` and collection
fixtures carry over. The churn is concentrated in the extensibility surface, so a project with no
custom orderer, no `IAsyncLifetime` and no output helper is usually a csproj-only change.

## Coverage — the half that fails silently

**Measured, and it is the worst failure mode in this migration.** Under the Microsoft Testing
Platform, the VSTest collector is *ignored*:

```bash
dotnet test --nologo --collect:"XPlat Code Coverage" --results-directory coverage
#  -> exit 0
#  -> Passed! Failed: 0, Passed: 6, Total: 6
#  -> coverage/ : does not exist. No file. Anywhere.
#  -> the only trace is: warning MTP0001: VSTest-specific properties … will be ignored
```

Green CI, green tests, zero coverage, and a warning nobody reads. `scripts/report-dashboard.py`
then renders "no coverage" for an app that is in fact tested — the report lies, in the direction
that looks fine.

The fix has two halves, and **both** are required:

1. The test project references `Microsoft.Testing.Extensions.CodeCoverage`.
2. CI collects the MTP way:
   ```bash
   dotnet test --nologo -- --coverage --coverage-output-format cobertura \
     --coverage-output "$PWD/coverage/coverage.cobertura.xml"
   ```

⚠ **The two packages are one decision, not two pins.** xunit.v3 and the coverage extension both
bind to Microsoft.Testing.Platform, so their major lines must agree:

| xunit.v3 | Microsoft.Testing.Platform | Microsoft.Testing.Extensions.CodeCoverage |
|---|---|---|
| **3.x** — the current stable line | v1 | **17.x** |
| **4.x** — `xunit.v3.mtp-v2`, still prerelease | v2 | **18.x** |

The map constrains the **major line only**; resolve the exact version from the live feed as
everywhere else in this guide. Move one leg alone and you get a clean restore, a clean build, and
a run-time death:

```
Unhandled exception. System.TypeLoadException: Could not load type
'Microsoft.Testing.Platform.Extensions.TestHost.IDataConsumer' from assembly
'Microsoft.Testing.Platform, Version=2.3.0.0'
```

**This rule is enforced, not merely written here** — prose did not stop the mistake the first
time. `MTP_COMPAT` in `<kit>/tests/xunit-v3/apply-transform.py` holds the mapping and
`validate_pairing` refuses a mismatched pair at start-up, naming both versions instead of leaving
the next reader to decode that stack trace; a xunit.v3 major the map does not know is refused too,
rather than paired with a guess. `<kit>/renovate.json` groups the two packages so an update
proposes **both legs in one PR**, which is where a split bump would realistically come from.

`<kit>/templates/ci-dotnet.yml` already does all of this: it detects the platform from the
csproj files, branches to the right collection command, and **fails the job when no
`coverage.cobertura.xml` was produced** — because a collection that silently yields nothing must
not read as a pass.

## Exit gate — count the tests, do not trust the build

The item is green **only** when the test run reports a count **≥ the phase-2 baseline count**, and
that number goes into `migration/report.md`. A successful build is explicitly rejected as evidence:
the whole failure mode of this change is a suite that stops running while everything still looks
fine.

```bash
dotnet test <test-project>.csproj --nologo    # then read Total: N, compare to the baseline
```

Red, or a count below baseline → revert this item (one modernization per commit, per phase 5's
rollback rule) and record why.

## Executable form

The transform is not only prose: `<kit>/tests/xunit-v3/apply-transform.py` applies it, and
`<kit>/tests/xunit-v3/test.sh` proves it end to end against a scratch copy of
`samples/LegacyShop` — 6 tests before, 6 tests after, the namespace rewrite exercised, and the
no-`Exe` variant pinned. Read the script when this file is ambiguous; it is the witness.

It **verifies its own work and refuses rather than half-applying**: if the v3 reference, the MTP
properties or `OutputType` did not land, or a v2 package survived, it exits non-zero instead of
reporting success — a transform that silently did nothing produces exactly the broken state this
item exists to prevent. It also only retargets TFMs *below* the v3 floor and never collapses a
multi-targeted list, so running it on a published library does not quietly drop a target.

⚠️ `samples/LegacyShop` itself stays on **xunit 2.4.2 / net6.0** permanently — it is the kit's
"before" state and CI asserts it stays green *and* legacy. Every experiment runs on a copy.
