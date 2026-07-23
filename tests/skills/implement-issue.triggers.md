# Triggering tests — implement-issue

Bench: skill-creator evals. Target: ≥ 90% of "should" queries, none of the "should NOT" queries.

CI (check-frontmatter.py) guards only that this list exists with both sections; the bench
itself is manual — re-run it via skill-creator whenever the skill's description changes.

## Should trigger

- "implement issue 47"
- "knock out the tasks on issue 71"
- "execute the plan on this issue and mark the PR ready"
- "build the feature from issue #12 and open a PR"
- "resume issue 47 where it left off"
- "pick up https://github.com/acme/app/issues/21 — go build it"
- "work through the checklist on issue 33"
- "the PR for issue 47 has conflicts with main, keep it mergeable" (PR still being built)

## Should NOT trigger

- "create an issue for the CSV bug" (→ create-issue)
- "merge PR 279" (→ merge-pr)
- "sync PR 281 so we can land it now" (sync in order to land → merge-pr)
- "add error handling to utils.py" (ad-hoc coding, no issue plan)
- "edit the plan on issue 47" (plan editing, not execution)
