---
description: Consolidate the migrated repos' open follow-ups (owner decisions, tasks, deferrals) and update them at the source
argument-hint: [repo-dir ...]
---

Invoke the `review-followups` skill.

Targets: each directory passed in `$ARGUMENTS` (otherwise, the migrated repos known from the
session/memory; otherwise, ask). Add the kit's backlog if accessible.

Discipline: aggregation exclusively via `<kit>/scripts/followups.py` (rule 7; path anchoring per
the skill); every update (done / closed by decision / addition) applies in the affected repo's
`migration/report.json`, with the dashboard regenerated and a commit — never a parallel list. When
owner decisions are waiting, offer to render them as a questionnaire (`--questionnaire`) and, once
answered, apply them back with `--ingest` (skill section "Handing the decisions to the owner").
Finish by presenting the consolidated view and the possible actions.
