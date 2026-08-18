# Triggering tests — auto-dev

Bench: skill-creator evals. Target: ≥ 90% of "should" queries, none of the "should NOT" queries.
The whole risk is overlap with its own children (`implement-issue`, `merge-pr`, `create-issue`):
auto-dev is the MANY-issues orchestrator, they are the one-issue/one-PR workers — so the
"should NOT" list is the critical part.

CI (check-frontmatter.py) guards only that this list exists with both sections; the bench
itself is manual — re-run it via skill-creator whenever the skill's description changes.

## Should trigger

- "implement issues small first then medium with 3 agents"
- "keep 3 agents continuously implementing and merging issues"
- "burn down the backlog"
- "run the auto-dev loop"
- "spin up a fleet of agents to clear the open issues"
- "auto-implement and merge everything that's ready"
- "work through the open issues hands-off, a few in parallel"
- « vide le backlog avec 3 agents »
- « lance la boucle auto-dev et préviens-moi quand c'est fini »

## Should NOT trigger

- "implement issue 47" (one issue → implement-issue)
- "merge PR 279" (one PR → merge-pr)
- "file an issue for this idea" (→ create-issue)
- "list the open issues" (read-only query, no fleet)
- "run these three test suites in parallel" (parallelism, but no issue lifecycle)
- "review the open PRs" (review → code-review)
