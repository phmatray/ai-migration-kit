# Triggering tests — setup-repo

Bench: skill-creator evals. Target: ≥ 90% of "should" queries, none of the "should NOT" queries.

CI (check-frontmatter.py) guards only that this list exists with both sections; the bench
itself is manual — re-run it via skill-creator whenever the skill's description changes.

The hard boundary this list is really testing is setup-repo vs `get-repo-profile`: one WRITES a
repo's configuration, the other only READS it. A query that asks for the configuration to exist
belongs here; a query that asks what the configuration currently is belongs there.

## Should trigger

- "set up the issue labels for this repo"
- "create the issue templates"
- "turn on auto-delete for merged branches"
- "configure this repository the way the kit expects"
- "we need priority and effort labels before running auto-dev"
- "why does auto-dev ignore my effort ordering?" (the axis does not exist yet)
- "make the repo settings deterministic instead of clicking through the UI"
- "check whether this repo's labels have drifted from our standard"
- « configure les labels du repo »
- « crée les templates d'issue »
- « supprime automatiquement les branches mergées »

## Should NOT trigger

- "set up the repo profile" (→ get-repo-profile; that reads and records, this one writes)
- "what labels does this repo have?" (a plain `gh label list`, no configuration change)
- "add the label 'priority: high' to issue 42" (→ labelling one issue, not the taxonomy)
- "create an issue for the CSV export" (→ create-issue)
- "merge PR 279 and delete the branch" (→ merge-pr; deleting ONE branch, not the repo setting)
- "set up branch protection rules" (explicitly out of scope — it needs org policy decisions)
- "configure my git user.name" (local git config, not the repository's GitHub configuration)
- "install the plugin" (kit installation, not repo configuration)
