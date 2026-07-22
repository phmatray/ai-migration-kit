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

## RoselineMCP calls

`apply_fixes`, `edit_member`, `rename_symbol`, `find_references`, `get_call_graph`.

## Exit gate

Build + tests green after **each** item; nullable warnings at zero in every project where `<Nullable>enable</Nullable>` was switched on.

## Rollback

One modernization item per commit; revert the item that broke and continue with the rest.
