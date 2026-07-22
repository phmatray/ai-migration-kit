# Phase 4 — Remediate

**Entry criteria:** phase 3 gate green (builds on new TFM).

## Steps

1. `list_diagnostics` on the solution → group by diagnostic ID, sorted by count.
2. **Mechanical IDs in bulk** (style, formatting, analyzer suggestions with a registered code fix): `apply_fixes` with `ids: [<one ID>]` in preview → inspect the returned diff → re-run with `previewOnly: false` → `dotnet test` → commit `migration: phase 4 fix <ID> (<n> sites)`. One ID per commit.
3. **Obsolete-API replacements** (judgment required — no auto-fix). Common swaps:
   | Legacy | Replacement |
   |--------|-------------|
   | `WebClient` (`SYSLIB0014`) | `HttpClient` (shared instance, async) |
   | `BinaryFormatter` (`SYSLIB0011`) | `System.Text.Json` |
   | `Thread.Abort` | `CancellationToken` |
   | `Remoting` / `AppDomain` isolation | out-of-process or `AssemblyLoadContext` |
   For each: `find_references` on the legacy type → rewrite each use site with `edit_member` (preview → apply) → keep signatures compatible in this phase (sync façade over async is acceptable here; true async is phase 5).
4. Loop steps 1–3 until `list_diagnostics` reports **0 errors** and warning count ≤ the phase-2 baseline.
5. Full `dotnet test` green.

## RoselineMCP calls

`list_diagnostics`, `apply_fixes` (preview → apply), `find_references`, `edit_member` (preview → apply).

## Exit gate

0 errors; warnings ≤ baseline from `migration/baseline.md`; all tests green.

## Rollback

One diagnostic ID (or one API swap) per commit — revert the offending commit, re-run the loop.
