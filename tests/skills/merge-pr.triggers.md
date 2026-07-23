# Triggering tests — merge-pr

Bench: skill-creator evals. Target: ≥ 90% of "should" queries, none of the "should NOT" queries.
Very generic verb ("merge") — the "should NOT" list is the critical part.

CI (check-frontmatter.py) guards only that this list exists with both sections; the bench
itself is manual — re-run it via skill-creator whenever the skill's description changes.

## Should trigger

- "merge PR 279"
- "land #281"
- "ship this PR"
- "can you get that PR merged once CI's green?"
- "wrap up 279 and open follow-ups for the deferred bits"
- "close out the open PR on the export feature"
- "https://github.com/acme/app/pull/279 — merge it"

## Should NOT trigger

- "merge main into my branch" (syncing a PR still being built → implement-issue)
- "git merge these two branches locally" (local git operation, no PR)
- "review PR 279 without merging" (review → code-review)
- "implement issue 47" (→ implement-issue)
- "how does GitHub squash-merge work?" (informational question)
