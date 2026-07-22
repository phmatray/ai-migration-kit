---
description: Re-runnable final quality gate for a migrated app — clean build, tests, diagnostics vs baseline, report
argument-hint: [path-to-solution]
---

Invoke the `legacy-upgrade` skill and run **phase 6 (Verify) only** — see `references/phase-6-verify.md`.

Target: `$ARGUMENTS` if given, otherwise auto-discover the solution from the current working directory.

This command is re-runnable at any time on a migration branch. If any gate fails (build, tests, `analyze_solution` vs `migration/baseline.md`), report exactly which gate failed and which phase owns the fix — do not write `migration/report.md` until everything is green.
