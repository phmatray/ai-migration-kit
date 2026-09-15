## Step 8 — Sync with `main` and resolve conflicts

`main` moves while this PR sits in draft. Mark it ready against a stale base and it merges with
conflicts — or won't merge. So before the final gate, merge the latest `main` into the branch, resolve
collisions, *then* re-verify on the merged tree (Step 9 is the proof — a clean textual merge is not a
clean semantic one).

Follow the shared procedure in [`../_shared/sync-with-main.md`](../../../_shared/sync-with-main.md)
(merge-not-rebase, the conflict rule-of-thumb keyed off the profile's *Conflict hot-spots*, and
finish-and-verify); `references/github-mechanics.md` §7 has the implement-issue framing. If a conflict
is genuinely ambiguous — both sides rewrote the same logic — stop and surface it with both sides shown
rather than guessing (Autonomy contract). Note the race: if another PR merges *after* you sync but
before this lands, re-run this step — it's cheap, and a re-sync right before merge is the surest path to
a clean integration.

---
