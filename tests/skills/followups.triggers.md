# Triggering tests — followups

Bench: skill-creator evals (already passed 16/16 vs 12/16 without the skill, v1.5.0). Target:
≥ 90% of "should" queries, none of the "should NOT" queries.

CI (check-frontmatter.py) guards only that this list exists with both sections; the bench
itself is manual — re-run it via skill-creator whenever the skill's description changes.

## Should trigger

- "what's still open across the migrated repos?"
- "status of the follow-ups"
- "what remains to be done on the migrations?"
- "give me the open tail of pending decisions"
- "mark that follow-up as done"
- "we won't do that one, close it by decision"
- "a new follow-up came up after the migration, add it"
- "/migrate-followups"

## Should NOT trigger

- "follow up with the client tomorrow" (human follow-up, not the migration queue)
- "add a TODO in the code" (code comment)
- "what remains in the sprint backlog?" (product backlog, not the report.json queues)
- "create an issue for this bug" (→ create-issue)
- "what's the status of CI?" (build status, not follow-ups)
