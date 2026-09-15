## Step 6 — Implementation plan (visible, with checkboxes)

Follow [`../_shared/plan-shape.md`](../../../_shared/plan-shape.md), applied autonomously to the Step 5
spec, shaping tasks to the profile's *Architecture grain* (layer order + invariants a plan must not
break). Tasks bite-sized and each independently testable.

**Preserve the `- [ ]` checkbox format, and keep this section OUTSIDE any `<details>`.** GitHub renders
those as live tickable checkboxes *and* counts them in the progress meter — but only while they sit in
the open body. Two ways to throw that away, both forbidden: flattening steps into `- **Files:**` /
`- **Test:**` prose, or burying the plan in a collapsed `<details>` (the meter may stop counting it).
Keep it a flat, visible section under a `## 🛠️ Implementation plan` heading — exact phrase;
`implement-issue` anchors on it.

The plan MUST carry all three:

1. The **header note** from `plan-shape.md` §Header note, **verbatim** — copy it from there, never
   from memory; it has one home so the executor it names cannot drift between copies.
2. A short **Goal / Architecture / Tech Stack** preamble, then a `**Seams under test:**` line
   copied verbatim from the Spec's `### Testing decisions` heading, immediately before **Global
   Constraints** (version floors, architecture invariants from *Architecture grain*, commit identity
   from *Commit identity*, build constraints) — exact values from the spec and profile.
3. One `### Task N: <name>` per task, each with **Files** + **Interfaces** lines, then **every step as its own `- [ ]` checkbox** (write the failing test → run red → implement → run green → commit). The final step is a `- [ ]` checkbox with the commit message. **Every failing-test step names the seam it crosses** — *"Write the failing case in `tests/skills/test.sh` (seam: check-frontmatter.py exit code + message)"* — drawn from the preamble's `Seams under test:` line; see [`../_shared/test-seams.md`](../../../_shared/test-seams.md) for the doctrine behind that choice.

**Pick one Conventional Commits type and use it consistently** in the Global Constraints
preamble's example (point 2 above) and every task's final commit-message step (point 3 above). The
rule for choosing it has one home, `plan-shape.md` §Commit type — apply it from there.

Shape (abbreviated — keep the checkboxes, never flatten to prose):

```markdown
## 🛠️ Implementation plan

> **For agentic workers:** execute this plan task-by-task with `implement-issue` …

**Seams under test:** the exporter's public `Export(ReportModel)` method — asserted through its
returned file content, never through a private formatting helper.

### Task 1: Export service + skeleton endpoint wired into the API

**Files:** create `Services/CsvExportService.cs`; modify `Program.cs` (DI registration); test `…/CsvExportServiceTests.cs`.

**Interfaces:** `CsvExportService : IExportService`, `Format => "csv"`, `Export(ReportModel)` returning the generated file.

- [ ] **Step 1:** Write the failing test in `CsvExportServiceTests.cs` (seam: `Export(ReportModel)`'s returned file content) — assert `Format == "csv"` and `Export` yields a header row.
- [ ] **Step 2:** Run that suite via the profile's *Build & test* single-suite filter → FAIL (types not found).
- [ ] **Step 3:** Implement `CsvExportService` — modeled on the existing `JsonExportService`, stdlib-only.
- [ ] **Step 4:** Re-run the suite filter → PASS.
- [ ] **Step 5:** Commit: `feat(export): CSV export skeleton + service`.
```

Drafting the plan in a **subagent** handed `plan-shape.md` preserves the format most reliably;
inline is fine too. Hold the plan markdown for Step 7's verify-checkboxes gate.

**You now know the real scope**, so settle on the **effort** size from what you wrote, matching the
profile's *Labels* taxonomy (one-task tweak = smallest; cross-layer/phased = largest). Apply it in Step 7.

### The decompose branch — when the plan would earn the largest effort size

**If the size you just settled on is the profile's largest** (`effort: large` here — "cross-layer /
phased") **and `--no-split` was not passed, do not file that plan as one issue.** A large issue is
one `auto-dev` holds at `HOLD` forever ("tier past the second") and one no single worker context can
carry — seven of the twenty-four open issues sat there when this branch was written, and #272
measured what happens when the fleet tries anyway. Decompose instead, per
[`references/decomposition.md`](../decomposition.md):

1. **Re-cut the plan into vertical slices.** Each slice is a *complete* path through every layer the
   job touches (for this kit: script + skill prose + golden test for one behaviour), demoable or
   verifiable alone, sized to one worker context — a plan that would earn `effort: small` or
   `effort: medium`. Any prefactoring is its own first slice. A **wide refactor** (one mechanical
   change fanning across the tree) is sequenced **expand → migrate batches → contract** instead.
2. **Give each slice its blocking edges** — the minimum set of siblings that genuinely gate it. A
   slice with no blockers can start immediately; the parent is never a blocker; no cycles.
3. **Write the parent's tracking body** per [`references/tracking-issue.md`](../tracking-issue.md):
   the template fields, `**Related:**`, the 🧠 Brainstorm and 📋 Spec you already have (the Spec's
   contract now describes the whole job), then `## Destination` · `## Notes` · `## Decisions so far`
   · `## Not yet ticketed` · `## Out of scope` (copied from the Spec's Out of scope). **No plan.**
   The parent must carry **none** of the strings `Implementation plan`, `### Task`, `- [ ]` — that
   absence is what keeps `survey.sh`'s `haveplan` false so the parent is never dispatched. Never
   relax it.
4. **Write one child body per slice**, each with its own full Step 6 plan (header note, preamble,
   `**Seams under test:**`, Global Constraints, `### Task` blocks with `- [ ]` steps), its own
   📋 Spec contract for the slice, and — as the first two lines — `Part of #<parent> — <parent
   title>.` and `**Blocked by:** <Blocker title> (#a), … ` or `none — can start immediately`. The
   parent's number is not known yet: leave `#<parent>` and every blocker number as placeholders
   Step 7 fills in as the issues come back.
5. **Size each child** on its own plan: small or medium. A child that would be large is not a slice
   — split again. The set must be **N ≥ 2**; a job that re-cuts to a single slice was not large.

With `--no-split`, skip this heading entirely: one issue, `effort: large`, exactly as before. With
`--seed #N` on a plan that would be large, the branch applies too — #N **becomes the parent** (the
tracking body goes below its `---` rule in place of a plan) and the children are new issues.
