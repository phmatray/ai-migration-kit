# Phase 5 — Modernize (opt-in)

**Entry criteria:** phase 4 gate green. This phase is optional — confirm scope with the user when interactive; default to the "safe set" below when running autonomously.

## Safe set (default)

Applied one item at a time, each followed by build + tests + commit:

1. `<ImplicitUsings>enable</ImplicitUsings>` + remove now-redundant usings (`apply_fixes` for the using-directive IDs, e.g. IDE0005).
2. File-scoped namespaces (`apply_fixes` with the IDE0161 fix where available; otherwise `edit_member` per type).
3. `<Nullable>enable</Nullable>` **per project, leaf first**; annotate to zero nullable warnings using `edit_member`. If a project's annotation burden is large, enable `<WarningsAsErrors>nullable</WarningsAsErrors>` only after it reaches zero.
4. Async end-to-end where phase 4 left sync façades: `get_call_graph` (`direction: "callers"`) from the façade upward; convert the chain top-down; rename `X` → `XAsync` with `rename_symbol` (preview — verify the site count matches `find_references` — then apply).

## Extended set (only if requested)

Primary constructors, collection expressions, records for DTOs, DI container adoption, minimal APIs. Same discipline: `find_references` before, `edit_member`/`rename_symbol` preview → apply, build + tests + commit after each.

### Test platform — xunit v2 → xunit.v3

Full procedure: **`references/xunit-v3-migration.md`**. It is in the *extended* set, never the safe
set: it changes how the tests **run**, which the safe-set items do not. It is also never done in
phase 3 — the v3 floor (`net8.0+` / `net472+`) is only cleared once the retarget has landed, and
folding a test-host swap into the retarget's gate makes a red build impossible to attribute.

Phase 1 recorded `testStack[].xunitMajor`. If it reads `2`, this item is *available*; run it only
when the extended set was requested, and only if all four preconditions in the reference hold.
**Any precondition that fails is a recorded deferral** — written into the report with the blocker
named (`deferred: <package> has no v3 build`) — never a silent skip.

Two things make this item different from every other one on this page:

- **The exit gate counts tests, it does not read the build.** Green is `dotnet test` reporting a
  count **≥ the phase-2 baseline count**. The failure mode here is a suite that stops running
  while the build stays green, so "it compiles" is explicitly not evidence.
- **Coverage does not survive on its own.** Under the Microsoft Testing Platform the VSTest
  collector is ignored *silently* — exit 0, tests pass, no coverage file. The reference carries
  the fix (coverage extension + MTP collection); `<kit>/templates/ci-dotnet.yml` already detects
  the platform and fails the job when nothing was collected.

## RoselineMCP calls

`apply_fixes`, `edit_member`, `rename_symbol`, `find_references`, `get_call_graph`.

## Exit gate

Build + tests green after **each** item; nullable warnings at zero in every project where `<Nullable>enable</Nullable>` was switched on.

## Rollback

One modernization item per commit; revert the item that broke and continue with the rest.
