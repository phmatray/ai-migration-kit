# Triggering tests — triage-backlog

Bench: skill-creator evals. Target: ≥ 90% of "should" queries, none of the "should NOT" queries.

CI (check-frontmatter.py) guards only that this list exists with both sections; the bench itself is
manual — re-run it via skill-creator whenever the skill's description changes.

The hard cases here are the near-misses against the three sibling lifecycle skills. `create-issue`
opens work, `merge-pr` files follow-ups while landing a PR, `followups` owns the migration reports'
queues in customer repos — this skill owns only the *existing* GitHub backlog and the decision to
stop carrying part of it.

## Should trigger

- "triage the backlog"
- "the follow-ups never end — every PR I close spawns three more issues, what do we do?"
- "go through the open issues and tell me which ones we should just close"
- "groom the issue list, it's at 30 and climbing"
- "why does the backlog keep growing even though we merge every day?"
- "clean up the open issues, half of them are probably already fixed"
- "prune the issue queue — anything stale or duplicated"
- "take stock of what's open and propose what to drop"
- « fais le tri dans les issues ouvertes »
- « le backlog ne descend jamais, qu'est-ce qu'on ferme ? »

## Should NOT trigger

- "create an issue for this bug" (→ create-issue — opening work, not re-deciding it)
- "file these three ideas as issues" (→ create-issue, batch form)
- "what's still open across the migrated repos?" (→ followups — report.json queues, not GitHub issues)
- "we won't do that follow-up, close it by decision" (→ followups when it names a migration follow-up; only this skill when it names a GitHub issue)
- "merge PR 279 and open the follow-ups" (→ merge-pr — filing at the inlet, mid-merge)
- "implement issue 47" (→ implement-issue)
- "burn down the backlog with 3 agents" (→ auto-dev — draining by building, not by deciding)
- "close issue 158" (a single explicit close — just do it with `gh`, no triage pass needed)
- "clean up the merged branches" (→ git housekeeping, not the issue queue)
- "review this PR for bugs" (→ code-review)
