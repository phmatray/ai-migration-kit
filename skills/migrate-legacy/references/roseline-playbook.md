# RoselineMCP Playbook

Task → tool mapping for the migration pipeline. All tools take an optional `project` (name, directory, `.csproj` or `.sln` path); pass the target solution path explicitly when running outside the server's working directory.

## Read / analyze (never modify files)

| You need | Call | Key params |
|----------|------|-----------|
| Solution health snapshot (error/warning/info counts) | `analyze_solution` | `pathOrGit`, `severity: "Warning"`, `maxDiagnostics` |
| Enumerate concrete fixable issues by diagnostic ID | `list_diagnostics` | `project` |
| Find a type/method or see a file's shape | `search_symbols` | pattern, `project` |
| One symbol's signature, docs, base types, body | `get_symbol_info` | `symbol`, `includeSource: true` |
| Resolve a `file:line` from a build error or stack trace to a symbol | `get_symbol_at_position` | `file`, `line` |
| Blast radius before changing/removing an API | `find_references` | `symbol`, `max` |
| Who calls this / what does it call | `get_call_graph` | `method`, `direction`, `depth` (1–3) |
| Base/derived tree of a type | `get_type_hierarchy` | `type`, `direction` |
| Who implements this interface / overrides this member | `find_implementations` | `symbol` |
| Diff two text blobs (e.g. csproj before/after for the report) | `create_patch` | `before`, `after`, `fileName` |

## Mutate (ALWAYS preview first)

| You need | Call | Discipline |
|----------|------|-----------|
| Bulk-fix mechanical diagnostics (e.g. `SYSLIB0014`, `CA1305`, style IDs) | `apply_fixes` with `ids: [...]` | 1st call: preview (default) → inspect diff → 2nd call: `previewOnly: false` |
| Replace / add / delete a single member surgically | `edit_member` | Same preview-then-apply discipline; prefer over whole-file rewrites |
| Rename a symbol solution-wide | `rename_symbol` | Preview, check the reference count matches `find_references`, then apply |

## When NOT to use RoselineMCP

- `.csproj`, `.sln`, `.config`, `.json`, docs → plain Read/Edit (Roseline is for C# code).
- Non-.NET languages → the ecosystem's own tooling.
- Running builds/tests → `dotnet build` / `dotnet test` in Bash; Roseline analyzes, it does not build artifacts.

## Standard sequences

**Build error triage:** build output gives `File.cs(42,13): error CS0246` → `get_symbol_at_position(file, 42)` → `get_symbol_info` on the result → fix via `edit_member` or csproj/package change.

**Bulk remediation loop (phase 4):** `list_diagnostics` → group by ID → for each mechanical ID: `apply_fixes` preview → inspect → apply → `dotnet test` → commit → repeat until `list_diagnostics` shows 0 errors.

**Safe API change (phases 3/5):** `find_references(symbol)` → if callers span projects, plan the change bottom-up → `edit_member`/`rename_symbol` preview → apply → build.
