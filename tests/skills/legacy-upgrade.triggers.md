# Triggering tests — legacy-upgrade

Bench: skill-creator evals (Anthropic skills guide, Testing chapter). Target: the skill loads on
≥ 90% of "should" queries and on none of the "should NOT" queries.

CI (check-frontmatter.py) guards only that this list exists with both sections; the bench
itself is manual — re-run it via skill-creator whenever the skill's description changes.

## Should trigger

- "upgrade this app to the latest .NET"
- "migrate this project to .NET 10"
- "modernize this legacy codebase"
- "this project targets an old framework, can you fix that?"
- "the runtime is out of support, bring it up to date"
- "these packages are ancient, get this solution current"
- "/migrate" / "/migrate-assess" / "/migrate-verify"

## Should NOT trigger

- "upgrade my npm dependencies" (dependency bump, not a legacy app migration)
- "help me write a new .NET app from scratch" (greenfield, not a migration)
- "migrate this database to Postgres" (data migration, not an app)
- "what's new in .NET 10?" (informational question)
- "merge PR 279" (→ merge-pr)
