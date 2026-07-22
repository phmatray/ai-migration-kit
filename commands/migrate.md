---
description: Run the full six-phase legacy upgrade pipeline (assess → verify) powered by RoselineMCP
argument-hint: [path-to-solution]
---

Invoke the `legacy-upgrade` skill and run the **full pipeline, phases 1 through 6**, on the target application.

Target: `$ARGUMENTS` if given (a `.sln` path or directory), otherwise auto-discover the solution from the current working directory.

Non-negotiables from the skill: RoselineMCP for all C# analysis/mutation, preview-first mutations, a red gate stops the pipeline, dedicated `migration/<yyyy-mm-dd>` branch, commit at every green gate. Finish by presenting `migration/report.md` to the user.
