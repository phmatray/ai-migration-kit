---
name: followups
description: >-
  Consolide et met à jour les suivis ouverts des migrations (next_steps/deferred des
  migration/report.json + backlog du kit). Use whenever the user asks what remains open, wants a
  status of pending decisions or follow-ups across migrated repos, says a follow-up item is done,
  or decides to close/abandon one — triggers on « fais le point », « qu'est-ce qui reste »,
  « suivis », « c'est fait, coche-le », « on ne le fera pas », "what's still open", "status of the
  follow-ups", "next steps", "mark it done", "we won't do that one", /migrate-followups. Also run
  it at the end of every migration (phase 7) so the open tail stays current.
license: MIT
compatibility: >-
  Requires python3 (scripts/followups.py) and read access to the migrated repos'
  migration/report.json; git to commit updates at the source.
metadata:
  author: Philippe Matray
  version: 1.7.0
  suite: ai-migration-kit
---

# Migration follow-ups — aggregation and updates

The pipeline delivers verified apps **and** a queue of follow-ups: decisions that belong to the
owner alone, quick tasks, deliberate deferrals. That queue already lives, structured, in each
migrated repo's `migration/report.json` (`next_steps`, `deferred`) — this skill surfaces it and
updates it **at the source**. Never a parallel list: a separate tracker would diverge from the
reports, which are the executive truth and the dashboard's input.

Throughout, **`<kit>`** is the plugin root — resolve it as `<skill-dir>/../..`, where
`<skill-dir>` is this skill's base directory (given when the skill loads). Kit script paths
resolve from there, never from the current working directory.

## Taking stock

1. Determine the repos: those passed as arguments, else the migrated repos known from the
   conversation/memory, else ask. Add `--backlog <kit>/docs/backlog.md` if the kit repo is
   accessible (trigger-tagged debts).
2. Run the kit's tool (mandatory — rule 7, never manual aggregation):
   ```bash
   python3 "<kit>/scripts/followups.py" <repo1> <repo2> … --backlog "<kit>/docs/backlog.md"
   ```
3. Present the output as-is (it is already sorted: owner decisions first, then tasks by
   increasing effort) and offer the next moves: settle a decision, run a quick task, or close
   by decision.

The tool flags repos without a `migration/report.json` — that is an error to surface, not to
mask (a migrated repo without a report has a bigger problem than its follow-ups).

## Marking a follow-up "done"

A finished follow-up disappears from `next_steps` — history lives in git, not in the JSON:

1. In the affected repo: remove the entry from `next_steps` in `migration/report.json`.
2. In `migration/report.md`, tick the matching line (`- [x] …`) — the readable trace.
3. Regenerate the dashboard: `python3 "<kit>/scripts/report-dashboard.py" migration/report.json`
   (the output lands next to the report.json).
4. Commit in that repo: `chore: follow-up closed — <item summary>`.

If the accomplishment deserves proof (e.g. "PWA installed on device"), ask for it or note it in
the commit message — the kit's doctrine is "done = verified".

## Closing by decision ("we won't do it")

Abandoning a follow-up is a legitimate, **documented** state, never a silent deletion:

1. Remove the entry from `next_steps` and add it to `deferred`:
   ```json
   { "strong": "Not pursued by decision (YYYY-MM-DD)", "text": "<the original item — and the reason if given>" }
   ```
2. Tick/annotate the line in `report.md` (`- [x] ~~…~~ — not pursued by decision`).
3. Regenerate the dashboard, commit: `chore: follow-up closed by decision — <summary>`.

The precedent: popcorn-time, "not pursued by decision, not by lack of capability".

## Adding a follow-up discovered after the fact

Add to `next_steps` using the report's format: `{ "text": …, "effort": "~N min", "owner": true }`
if the decision belongs to the owner — then dashboard + commit, as above.

## Converting a follow-up into a GitHub issue

When the target repo lives on GitHub, a follow-up that deserves a real ticket converts via the
kit's **`create-issue`** skill (brainstorm → spec → implementation plan in the issue body, repo
profile via `get-repo-profile`). The report stays the truth — never a parallel list: add the URL
to the entry (`"issue": "https://github.com/…/issues/N"`) rather than removing it, then
dashboard + commit. The follow-up closes through the "done" protocol once the issue is closed;
the issue points at the repo, the entry points at the issue.

## Guard-rails

- **Every mutation happens in the target repo and is committed there** — a follow-up modified
  without a commit does not exist.
- The kit's backlog (`docs/backlog.md`) is hand-edited (its entries carry their YAGNI trigger);
  this skill reads it, it does not rewrite it.
- Never invent items: everything comes from the reports, the backlog, or an explicit request.
