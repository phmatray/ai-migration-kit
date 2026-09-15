## Step 5 — Brainstorm & Spec (collapsible body sections)

Follow [`../_shared/brainstorm-and-spec.md`](../../../_shared/brainstorm-and-spec.md), applied
**autonomously** (no questions, pick the recommended option, note assumptions). Its two halves are
the two sections below, so the trail reads brainstorm → spec.

**Before you write the approaches, consult the accepted ADRs for the idea's area.** Run `search_adrs`
(mode `semantic`, status `accepted`) through the `adr` server; without it, grep `docs/adr/*.md`
frontmatter for `status: accepted` and the area tag, and say so ("ADRs read from files; AdrMcp not
connected"). The repo profile's *ADRs* section names the root — `none` means there is nothing to
consult, which is a sentence you write rather than a step you skip silently. The brainstorm then
states, per hit, *consistent with ADR-N* or *contradicts ADR-N — reopening because …*. A
contradiction is a finding the owner sees, never a silent override, and every cited id goes on the
`**Related:**` line (Step 7).

**If `--grill` was passed, the round goes between the two halves of this step: brainstorm → grill →
Spec.** "Passed" means a standalone token at an edge of the request (*Inputs*, above) — an idea whose
own sentence happens to quote `--grill` never opens a round. Not before the brainstorm —
[`../_shared/grilling.md`](../../../_shared/grilling.md) defines the
frontier by *exclusion* against what the brainstorm already settles ("a decision the evidence already
makes is not on the frontier"; "state it as a finding in the brainstorm"), and neither filter can be
applied to a brainstorm that does not exist yet. So write the 🧠 Brainstorm first, then apply the
primitive once: compute the frontier — the decisions the brainstorm could **not** make from the
evidence (which public surface, which default ships, whether compatibility may break, where the scope
boundary falls) — and put the whole frontier to the user in **one** numbered round, every question
carrying your recommended answer. Facts are never questions: dispatch a sub-agent for anything you
could look up. Wait for one reply; answered questions become fixed decisions the 📋 Spec states as
design rather than as options with trade-offs, and every unanswered one takes its recommended answer
and is listed in the Spec's **Assumptions** note as *asked, unanswered — took `<recommendation>`*.
There is no second round. Without `--grill`, skip this paragraph entirely.

**🧠 Brainstorm** — focused, not a wall of text: *Problem/context* (what need, who, what exists — cite
README / roadmap / code); *Approaches* (2-3 options with honest trade-offs); *Recommendation* (pick one
and why — this drives the spec and plan).

**📋 Spec** — the formal design for the recommended approach (goal, scope/non-goals, the public
surface or behavior, key types/files, validation rules, edge cases, an Assumptions note).
Where the design has *shape* — a state machine, a
context map, an aggregate — embed a **mermaid diagram**; GitHub renders it inline. Use it where it
clarifies; don't decorate.

**The Spec ends with a contract.** After the design prose, close with exactly these three headings,
in this order:

```markdown
### Acceptance criteria

1. AC1 — <behavioural, independently verifiable: "running X prints Y", "the suite fails when Z">
2. AC2 — …

### Testing decisions

**Seams under test:** <the public boundary each test observes through — a script's exit code + stdout, a stubbed `gh`, a rendered file>. Existing seams first; new ones at the highest point possible; the ideal number is one.
**Prior art:** <a test in the tree that already crosses this seam, e.g. `tests/survey/test.sh`'s gh stub>.
**A good test here:** <one line, in the terms of [`../_shared/test-seams.md`](../../../_shared/test-seams.md)>.

### Out of scope

- <a thing a reviewer might expect and must not find in the PR>
```

Criteria are a **numbered list, never `- [ ]`** — Step 7's readback and `implement-issue`'s
`tick-plan.sh` both count every `- [ ]` checkbox in the body, so a checkbox here would inflate the
plan's checkbox count and could be ticked by a plan step that never satisfied it. Each criterion must
be checkable without reading the diff. "Out of scope" names at least one item, or says
`nothing adjacent` explicitly — a reviewer needs something quotable, not an empty heading. For a
docs-only issue the seams line reads `none — no executable surface changes` and Prior art is omitted.
See [`../_shared/test-seams.md`](../../../_shared/test-seams.md) for what a seam is and the anti-patterns
a bad seam choice produces.

Render both as **collapsible sections** so the description stays scannable. GitHub needs a blank line
after `</summary>` (and before `</details>`) or the Markdown won't render:

```markdown
<details>
<summary><b>🧠 Brainstorm</b></summary>

… problem / approaches / recommendation …

</details>

<details>
<summary><b>📋 Spec</b></summary>

… design doc, with a mermaid diagram where it helps …

</details>
```
