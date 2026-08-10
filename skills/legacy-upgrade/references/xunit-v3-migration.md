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

⚠️ `samples/LegacyShop` itself stays on **xunit 2.4.2 / net6.0** permanently — it is the kit's
"before" state and CI asserts it stays green *and* legacy. Every experiment runs on a copy.
