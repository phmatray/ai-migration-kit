# The closing recap — one shape, one hand-off table

Every skill in the kit ends by telling the user what it did. Before this file, every one of them
invented that ending from scratch: four spelled it out as a numbered `Report` step, each asking for
a different set of things (`merge-pr` reported cleanup and `implement-issue` did not; `auto-dev`
reported cost and nobody else did), four spelled it out nowhere at all, and three of them
independently remembered to ask for "anything assumed, deferred, or unverifiable" — three sentences
saying the same thing, which is the drift signature this repo has already paid for in
`tests/_lib.sh` (#72), `tests/_lib/py_module.py` (#42) and the caller-path base (#143).

Worse, the one line the user actually acts on next — `/implement-issue #N` after `create-issue` —
existed as prose in exactly two of them, while [`ARCHITECTURE.md`](../../ARCHITECTURE.md) drew the
same hand-offs as dashed mermaid edges. **Two documentations, zero checks.** `merge-pr` landed a PR
and said nothing about what to do next even though the graph knew the answer; `profile-repo`
exists to bootstrap `create-issue` and never said so.

So the shape lives here, the hand-off lives here, and
[`scripts/recap-wiring-check.py`](../../scripts/recap-wiring-check.py) keeps the skills, this table
and `ARCHITECTURE.md`'s dashed edges in agreement — a gate that can actually go red, rather than a
convention held by everyone remembering it.

This is a **reference**, not a template the skills `cat` — same as
[`preconditions.md`](preconditions.md) and [`sync-with-main.md`](sync-with-main.md).

---

## The shape

A fixed sequence, the same order in every skill, **every block mandatory**:

```markdown
## ✅ <skill-name> — <one-line verdict>

**What happened** — the results, 1–5 bullets. Not a narration of the steps.

**Artifacts** — every URL or path this run produced or changed: issues, PRs, commit shas, files.

**Assumed · skipped · unverified** — every default taken, gate not run, item declined, prerequisite
missing.

**Next** — the command(s) from the hand-off table below, with the live number substituted.
```

Four rules make it worth having:

1. **The verdict comes first, on the heading line.** A reader who stops after one line still learns
   the outcome. `✅` / `⚠️` / `❌` — never a bare restatement of the skill's name.
2. **`What happened` is results, not steps.** "Filed #241 and #242; folded the third idea into
   #187" — not "ran the brainstorm, then wrote the spec, then applied labels."
3. **`None` is a required answer, not an omission.** An empty *Assumed · skipped · unverified*
   block is written as `None` — silence and nothing-to-report must not look alike. Same principle
   as `repo-profile.sh show` printing `NO_PROFILE` rather than staying quiet (#157): a named
   "nothing" is a verdict; an absent line is not.
4. **`Next` is copied from the table, not invented.** `—` when the skill is terminal — again a
   stated nothing, so "no next step" and "forgot the row" stay distinguishable.

A skill may add rows of its own **after** these four when it genuinely has something the shape does
not carry — `merge-pr`'s branch/worktree teardown, `auto-dev`'s cost accounting. It may not drop
one, reorder them, or restate a block the reference already defines.

---

## The hand-off table

The single source for "what command comes after skill X". `ARCHITECTURE.md`'s dashed edges are
checked against it; they are not a second copy to hand-sync.

| Skill | Ends with | Next command |
|---|---|---|
| `profile-repo` | the profile written, or read back | `/setup-repo` when it named a missing label axis or issue-form dir, then `/create-issue <idea>` |
| `setup-repo` | the repo converged on its manifest | `/profile-repo --refresh` |
| `create-issue` | issue(s) filed, each with a plan | `/implement-issue #<issue>` |
| `implement-issue` | PR **ready**, not landed | `/merge-pr #<pr>` |
| `merge-pr` | PR merged, follow-ups filed | `/implement-issue #<next-issue>` |
| `auto-dev` | the eligible queue drained | `/implement-issue #<held-issue>` for anything held as L/XL, else `—` |
| `triage-backlog` | every open issue re-decided | `/implement-issue #<kept-issue>` |
| `followups` | the open tail presented | `/create-issue <entry>` to convert an entry |
| `legacy-upgrade` | phase 7 delivered | `/migrate-followups` |
| `systematic-debugging` | the root cause identified | `—` (it returns to whatever called it) |

**How the guard reads this table.** Backticked `/<name>` spans in the *Next command* cell are the
hand-offs; a cell with none is terminal. `<name>` resolves to `skills/<name>/` when that directory
exists, otherwise to the skill that `commands/<name>.md` invokes — which is how
`/migrate-followups` resolves to `followups`. Prose around the spans is free text: reword it
without fear, but do not spell a command outside backticks, where nothing can see it.

**A cell that names no command must say `—`.** An empty cell, or one that says "still deciding", is
refused — that is the same silence this file exists to end, and letting it read as "terminal" would
reproduce the defect inside the fix.

**A row is not optional.** Every `skills/<name>/` directory except `_shared/` has exactly one row,
so adding a skill without deciding what follows it refuses rather than passing quietly.

---

## What is *not* a hand-off

`ARCHITECTURE.md` draws two kinds of arrow between skills and only one of them belongs here:

- **Solid (`-->`) — one skill invokes another during its own run.** `merge-pr` files its deferred
  work through `create-issue` (`MP --> CI`); `triage-backlog` executes dispositions the same way.
  Nobody types a command; there is no hand-off, and no row.
- **Dashed (`-.->`) — the user's next command.** These are exactly the pairs this table declares.

The distinction is load-bearing: `merge-pr`'s row points at `/implement-issue`, while its solid edge
points at `create-issue`. Read the solid edge as a hand-off and the two contradict each other.
