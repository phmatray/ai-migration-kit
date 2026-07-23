---
description: Run the full seven-phase legacy upgrade pipeline (assess → verified production) powered by RoselineMCP
argument-hint: [path-to-solution]
---

Invoke the `legacy-upgrade` skill and run the **full pipeline, phases 1 through 7**, on the target application.

Target: `$ARGUMENTS` if given (a `.sln` path or directory), otherwise auto-discover the solution from the current working directory.

**Resume, never restart:** if the target already carries a `migration/` folder or a `migration/<yyyy-mm-dd>` branch, follow the skill's resume protocol — locate the last green gate (gate commits + artifacts), announce the resume point, and re-enter at the phase after it. A green phase is never replayed.

Non-negotiables from the skill: RoselineMCP for all C# analysis/mutation, preview-first mutations, a red gate stops the pipeline, dedicated `migration/<yyyy-mm-dd>` branch, commit at every green gate, delivered = verified in production (phase 7, delivery playbook). Finish by presenting `migration/report.md`, the verified production URL — or the recorded owner decision when no production target exists — and the up-to-date follow-ups queue.
