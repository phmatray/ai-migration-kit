# Triggering tests — get-repo-profile

Bench: skill-creator evals. Target: ≥ 90% of "should" queries, none of the "should NOT" queries.

CI (check-frontmatter.py) guards only that this list exists with both sections; the bench
itself is manual — re-run it via skill-creator whenever the skill's description changes.

## Should trigger

- "set up the repo profile"
- "make create-issue and merge-pr work in my other repo"
- "regenerate the repo profile, the CI gates changed"
- "configure this repo for the issue skills"
- "port the lifecycle skills to this repository"
- "refresh the profile, the labels changed"
- "generate the repo config the lifecycle skills read"

## Should NOT trigger

- "what's my GitHub profile?" (user profile, not the repo config)
- "create an issue" (→ create-issue; the profile loads as a precondition, not via this skill)
- "update my git config" (global git config, not the skills' profile)
- "show me the repo's README" (simple read)
- "profile this app's performance" ("profile" = perf profiling, not config)
