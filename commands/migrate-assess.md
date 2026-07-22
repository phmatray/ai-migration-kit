---
description: Read-only legacy audit — inventory, diagnostics, risk map, recommended target (no code changes)
argument-hint: [path-to-solution]
---

Invoke the `legacy-upgrade` skill and run **phase 1 (Assess) only** — see `references/phase-1-assess.md`.

Target: `$ARGUMENTS` if given, otherwise auto-discover the solution from the current working directory.

**Read-only guarantee:** the only file you may create is `migration/assessment.md`. No other file in the target repository is created or modified; use only read-only RoselineMCP calls (`analyze_solution`, `search_symbols`, `find_references`). Finish by presenting the assessment and offering `/migrate` as the next step.
