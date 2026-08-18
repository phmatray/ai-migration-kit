# Shared Filing Bar: what earns an issue

This reference is used by every inlet that can create issues on its own initiative — `merge-pr`
Step 6 (follow-ups from a merge), `create-issue` Step 3 (an idea it discovered rather than one it
was handed), and the `auto-dev` workers' off-scope capture. One bar in one place, because two
inlets applying different bars is how a backlog stops meaning anything.

## Why there is a bar at all

An issue is a **commitment to do work**. An observation is a **record that something is true**. Both
are worth keeping; only one of them belongs in a queue someone is expected to drain.

The arithmetic is unforgiving. Filing costs seconds and resolving costs a PR, so an inlet that files
everything it noticed adds work faster than any loop can remove it — and the queue's signal drops as
it grows, because the item that actually matters is now sitting behind twenty that don't. A backlog
nobody can triage is functionally the same as no backlog, except it also generates guilt.

So the bar is not a quality judgement on the finding. A true, well-argued, genuinely-correct
observation can fail it. The question is never *"is this real?"* — it is **"is this work someone
should commit to doing?"**

## The bar: pass one of three, and file

**1. Consequence — someone gets a wrong result.** You can name, in one sentence, what breaks for a
user of the kit or a migration it runs: a wrong output, a failed run, a gate that passes when it
should have gone red. *"On Windows two local gates refuse every suite they scan"* names it. *"This
could be more robust"* does not.

**2. A named instance already in the tree.** The gap is not hypothetical: you can point at the file,
symbol, or config that exhibits it today. *"The pinned-literals check covers exactly one pin — the
repo has three more"* passes, because the three exist and can be listed. *"A future copy of this
idiom would slip past the guard"* does not — no such copy exists yet, so there is nothing to fix,
only something to watch.

**3. Commitment already made.** The owner asked for it, or the PR itself deferred it as part of its
own declared scope (*"lands the parser, adornments in a follow-up"*). The decision to do this work
has already been taken; the issue is just where it now lives.

Pass one gate and the finding earns an issue. Pass none and it is an observation.

## Where a finding goes when it fails the bar

Record it — retrievable later, costing nothing to ignore in the meantime:

```bash
gh pr comment "$PR" --body "Noted while merging: … (recorded, not filed — no action planned)."
```

This is not a consolation prize. The day a hypothetical acquires a real instance, the comment is
right there in the PR that first noticed it, and *then* it passes gate 2 and earns its issue. Filing
early doesn't make that day come sooner; it just carries the item until then.

## The two edges worth getting right

**A direct request from the user always outranks the bar.** When someone says *"file an issue for
this"*, that is gate 3 — they have made the commitment, and it is not the skill's place to relitigate
it. The bar exists to govern what the pipeline files **on its own initiative**, which is the only
channel that can run away. If you think a requested issue is thin, file it and say why in one
sentence; don't refuse.

**Hardening work is not exempt, but it isn't disqualified either.** Much of what a careful reviewer
finds is second-order — tests about tests, gates about gates. That work is legitimate and this bar
does not exist to suppress it. Gate 2 is what keeps it honest: a hardening finding with a named
instance in the tree is real work; one written against a shape nobody has committed is a watch item.
The distinction is checkable, which is why it is the gate rather than a judgement call about
"importance".

## Applying it

Apply the bar **after** clustering by root cause, never before. A cluster of three symptoms is one
finding, and it is the *cluster* that faces the bar — judging symptoms individually is how three
weak items get filed separately when the one root behind them would have passed on its own merits.

Report what the bar did, in the skill's closing recap: *"7 observations · 2 filed · 5 recorded"*.
The count is what tells the owner whether the inlet is calibrated — all-filed means the bar isn't
being applied, all-recorded means it is being used to avoid work.
