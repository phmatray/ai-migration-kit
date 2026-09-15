# Shared Grilling Doctrine: ask the frontier once, recommend every answer

Ported from mattpocock/skills `productivity/grilling` (MIT), with one deliberate narrowing: Matt's
skill works a design tree over **rounds until the frontier is empty**, and this kit asks **one**
round. This file is the one home for the doctrine — `skills/create-issue/SKILL.md`'s `--grill` input
links here instead of restating it, and a future confirmation pass in `triage-backlog` is meant to
reuse the same format rather than grow a second dialect of it.

## Why one round, when the source asks until the frontier is empty

Every other flow in this kit runs **hands-off**: `merge-pr` Step 6 and the `auto-dev` workers file
issues with nobody watching, and their autonomy contract says to pick the most reasonable default and
keep going. A question asked to nobody is the never-wait failure (#187) — the process ends its turn
waiting for an answer that cannot arrive.

`--grill` is the one sanctioned exception, and it is sanctioned only because the *user typed it*:
passing the flag is the evidence that somebody is there to answer. That evidence covers one exchange,
not an open-ended interview — the user who asked for a grilling did not thereby promise to sit
through five rounds. So the primitive spends its single exchange on the questions that matter most,
and everything else takes a stated default. **A second round is a second `--grill` invocation**, which
is again the user's choice to make, rather than something the skill decides to spend their attention
on. Rounds-until-empty belongs to a human-in-the-loop planning skill this kit deliberately does not
have.

## The frontier

Map the decisions as a tree: every decision branches into the decisions that hang off it. The
**frontier** is every decision whose prerequisites are already settled — the questions you can ask
*now* without first guessing at an answer you have not heard yet.

Ask the frontier, and only the frontier:

- **A question whose answer depends on another question in this same round is not on the frontier.**
  It is downstream of one, and asking both at once produces an answer to the second that the first
  may invalidate. Drop it, take the recommended default for it, and note it — do not smuggle it into
  the round as a conditional ("if you picked A above, then…").
- **A decision the evidence already makes is not on the frontier either.** If the repo profile, the
  architecture grain, an existing convention, or a prior issue settles it, it is settled: state it as
  a finding in the brainstorm, don't spend a question on it. The frontier is *underdetermination*, not
  everything you happen to be uncertain about.

What is typically on it: which public surface a change lands on, which of two defaults ships, whether
compatibility may break, which of two consumers owns a mechanism, what the scope boundary is. What is
typically not: anything you could look up (see below), and anything the recommendation in the
brainstorm already argues for convincingly.

Keep the round small. Five or six questions is a frontier; fifteen is a questionnaire, and the answer
to a questionnaire is silence.

## One round

Number the questions, give each a title, and give **every** question your recommended answer.
The recommended answer is not a formality — it is what ships if the user says nothing (see below), so
write it as the decision you would actually make and stand behind:

```
❓ **Q1** - **<question title>**: <question body, possibly several paragraphs, laying out the options>

➡️ <your recommended answer>

---

❓ **Q2** - **<question title>**: <question body, possibly several paragraphs, laying out the options>

➡️ <your recommended answer>
```

Then wait for **one** reply. The user may answer all of it, some of it, or none of it; any of the
three is a complete reply and none of them earns a follow-up round.

## Facts are yours, decisions are theirs

Finding **facts** is your job, never the user's. Does that file exist, what does that test actually
assert, which version is pinned, is there already a helper for this — dispatch a sub-agent and look it
up. Asking the user a question you could have answered yourself spends the one exchange you have on
something you were supposed to bring to it.

Don't block on the lookup either. A running exploration is an unsettled prerequisite, so only the
questions *downstream* of it wait — and since there is one round, a question still waiting on a fact
when the round goes out is not on the frontier: take its recommended answer and note it.

The **decisions** are the user's: which surface, which default, what breaks. Put those to them.

## Unanswered → recommended answer, noted

Every question the reply does not answer takes its **recommended answer** — silently defaulting is
what the autonomy contract already does everywhere else, and this primitive changes only *whether the
user got a chance to intervene first*, never whether the flow stalls.

But it is not silent afterwards: each defaulted question is recorded under the Spec's **Assumptions**
note, in the form "*asked, unanswered — took `<recommended answer>`*", so the issue itself records
that a decision was offered and declined rather than never surfaced. That distinction is the whole
value of the round: a reader of the issue can tell a considered default from an unnoticed one.

Answers that *did* arrive are **fixed decisions** from that point on. They go into the Spec as design,
not as options with trade-offs still attached — re-litigating a settled question in the prose wastes
the exchange that settled it.
