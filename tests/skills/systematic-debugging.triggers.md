# Triggering tests — systematic-debugging

Bench: skill-creator evals. Target: ≥ 90% of "should" queries, none of the "should NOT" queries.
The skill must fire BEFORE a fix is proposed, and must stay out of the way of ordinary
feature work — so the "should NOT" list is about new code, not about debugging style.

CI (check-frontmatter.py) guards only that this list exists with both sections; the bench
itself is manual — re-run it via skill-creator whenever the skill's description changes.

## Should trigger

- "this test fails intermittently, can you fix it?"
- "the build broke after my last commit"
- "I get a NullReferenceException here, patch it"
- "the migration worked yesterday and now 500s"
- "why does this integration test hang in CI but pass locally?"
- « ce test est flaky, corrige-le »
- « ça marchait avant, maintenant ça plante au démarrage »

## Should NOT trigger

- "add a retry policy to this HTTP client" (new behavior, nothing broken)
- "refactor this service into smaller classes" (working code → refactoring)
- "write tests for this class" (new tests, no failure to explain)
- "set up a CI workflow" (tooling)
- "review this PR" (→ code-review)
- "how does the debugger attach to a container?" (informational question)
